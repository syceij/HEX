import Foundation
import Supabase

/// Singleton wrapper around the Supabase Swift client.
///
/// Exposes the raw `client` plus a small set of typed convenience methods
/// for auth + database. Views talk to this via async/await.
final class SupabaseManager {

    // MARK: - Singleton

    static let shared = SupabaseManager()

    // MARK: - Configuration

    /// Project URL.
    private static let supabaseURL = URL(
        string: "https://xfrzdyloocdfipfzmwge.supabase.co"
    )!

    /// Anon (publishable) key — safe to ship in the app.
    private static let supabaseAnonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhmcnpkeWxvb2NkZmlwZnptd2dlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1MTcyMzgsImV4cCI6MjA5MzA5MzIzOH0.fWuwS-QTXszYhFnUqH3GH9p_OhwTwY_0ZBdmMfQ8SAw"

    // MARK: - Client

    /// Raw Supabase client — use this for advanced queries.
    let client: SupabaseClient

    private init() {
        self.client = SupabaseClient(
            supabaseURL: Self.supabaseURL,
            supabaseKey: Self.supabaseAnonKey
        )
    }

    // MARK: - Auth helpers

    /// Currently signed-in user, or nil.
    var currentUser: User? {
        client.auth.currentUser
    }

    /// Sign in with email + password.
    func signIn(email: String, password: String) async throws -> Session {
        try await client.auth.signIn(email: email, password: password)
    }

    /// Look up the email stored on a profile row by username. Returns nil if
    /// no row matches. Used so users can sign in with either email or username.
    func emailForUsername(_ username: String) async throws -> String? {
        struct Row: Decodable { let email: String? }
        let rows: [Row] = try await client
            .from("profiles")
            .select("email")
            .eq("username", value: username.lowercased())
            .limit(1)
            .execute()
            .value
        return rows.first?.email
    }

    /// Check whether a username is already taken. Used for real-time
    /// availability hint on the signup screen.
    func isUsernameTaken(_ username: String) async throws -> Bool {
        struct Row: Decodable { let id: UUID }
        let rows: [Row] = try await client
            .from("profiles")
            .select("id")
            .eq("username", value: username.lowercased())
            .limit(1)
            .execute()
            .value
        return !rows.isEmpty
    }

    /// Sign up with email + password. Optionally pass extra metadata
    /// (name, username) that gets stored on the auth user.
    func signUp(
        email: String,
        password: String,
        metadata: [String: AnyJSON] = [:]
    ) async throws -> AuthResponse {
        try await client.auth.signUp(
            email: email,
            password: password,
            data: metadata
        )
    }

    /// Verify a 6-digit OTP code emailed to the user during signup.
    func verifyOTP(email: String, token: String) async throws -> AuthResponse {
        try await client.auth.verifyOTP(
            email: email,
            token: token,
            type: .signup
        )
    }

    /// Resend the signup OTP.
    func resendSignupOTP(email: String) async throws {
        try await client.auth.resend(email: email, type: .signup)
    }

    /// Sign out the current user.
    func signOut() async throws {
        try await client.auth.signOut()
    }

    // MARK: - Profile helpers

    /// Fetch the current user's profile row. Returns nil if no row exists.
    func fetchOwnProfile() async throws -> Profile? {
        guard let uid = currentUser?.id else { return nil }
        let rows: [Profile] = try await client
            .from("profiles")
            .select()
            .eq("id", value: uid)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Upsert (create or update) the current user's profile.
    func upsertOwnProfile(_ profile: Profile) async throws {
        _ = try await client
            .from("profiles")
            .upsert(profile)
            .execute()
    }

    /// Persist the user's tracked-lift slots. Mirrors React's
    /// `saveTrackedLifts(uid, slots)` writer in `src/lib/db.js`. Writing the
    /// same `{name, key}` shape on both clients means the slots stay in
    /// sync across iOS and web.
    func saveTrackedLifts(_ slots: [TrackedLift?]) async throws {
        guard let uid = currentUser?.id else { return }
        struct Patch: Encodable { let tracked_lifts: [TrackedLift?] }
        _ = try await client
            .from("profiles")
            .update(Patch(tracked_lifts: slots))
            .eq("id", value: uid)
            .execute()
    }

    /// Persist the user's display-language choice. Mirrors React's
    /// `handleSetLang` → `upsertProfile(uid, {lang})` in App.jsx — without
    /// this iOS flips AR↔EN only in memory and the next sign-in overrides
    /// the choice from the DB.
    func updateOwnLanguage(_ lang: String) async throws {
        guard let uid = currentUser?.id else { return }
        struct Patch: Encodable { let language: String }
        _ = try await client
            .from("profiles")
            .update(Patch(language: lang))
            .eq("id", value: uid)
            .execute()
    }

    /// Persist the user's display name. Mirrors React's name-edit flow
    /// in AccountPage / ProfileTab. Username is NEVER touched here —
    /// it's set once at signup and stays immutable.
    func updateOwnName(_ name: String) async throws {
        guard let uid = currentUser?.id else { return }
        struct Patch: Encodable { let name: String }
        _ = try await client
            .from("profiles")
            .update(Patch(name: name))
            .eq("id", value: uid)
            .execute()
    }

    /// Write the canonical signup-time profile row: `{id, name, username,
    /// email, language: 'en'}`. Mirrors React's AuthScreen post-OTP step.
    /// Username is captured ONCE at signup and never editable afterward —
    /// this is the ONE place in the app that writes to the username column.
    func upsertOwnSignupProfile(uid: UUID, name: String?, username: String?, email: String?) async throws {
        struct Patch: Encodable {
            let id: UUID
            let name: String?
            let username: String?
            let email: String?
            let language: String
        }
        _ = try await client
            .from("profiles")
            .upsert(Patch(
                id: uid,
                name: name,
                username: username,
                email: email,
                language: "en"
            ), onConflict: "id")
            .execute()
    }

    /// Insert a minimal profile row for this user if one doesn't yet exist.
    /// Mirrors the React `ensureProfileExists` flow exactly: SELECT first,
    /// only INSERT if the row is missing, populate `name` + `language` so
    /// we don't trip any NOT NULL constraints on those columns. Returns
    /// true if a row was just created (false if it already existed).
    @discardableResult
    func ensureOwnProfileRow(uid: UUID,
                              fallbackName: String?,
                              email: String?) async throws -> Bool {
        // 1. Check whether the row already exists.
        struct IDRow: Decodable { let id: UUID }
        let existing: [IDRow] = try await client
            .from("profiles")
            .select("id")
            .eq("id", value: uid)
            .limit(1)
            .execute()
            .value
        if !existing.isEmpty { return false }

        // 2. Insert the minimal row React's ensureProfileExists uses.
        let name: String = {
            if let fb = fallbackName, !fb.isEmpty { return fb }
            if let e = email, let prefix = e.split(separator: "@").first {
                return String(prefix)
            }
            return "Athlete"
        }()
        struct Seed: Encodable {
            let id: UUID
            let name: String
            let language: String
            let email: String?
        }
        _ = try await client
            .from("profiles")
            .insert(Seed(id: uid, name: name, language: "en", email: email))
            .execute()
        return true
    }

    /// Wipe all user-owned rows (programmes, sessions, sets, custom exercises,
    /// working weights, friendships, activity, invite links) but keep the
    /// auth.users row. Used by the AccountView "Reset all data" button.
    func resetUserData() async throws {
        guard let uid = currentUser?.id else { return }
        // Best-effort parallel deletes. We don't bail on individual failures
        // — if one of these tables doesn't exist yet, the others still get
        // wiped.
        async let p1: Void = deleteAll(table: "programmes", uid: uid)
        async let p2: Void = deleteAll(table: "sessions", uid: uid)
        async let p3: Void = deleteAll(table: "sets", uid: uid)
        async let p4: Void = deleteAll(table: "working_weights", uid: uid)
        async let p5: Void = deleteAll(table: "activity_feed", uid: uid)
        async let p6: Void = deleteAll(table: "invite_links", uid: uid)
        async let p7: Void = deleteAllFriendships(uid: uid)
        async let p8: Void = clearProfileBlobs(uid: uid)
        _ = try await (p1, p2, p3, p4, p5, p6, p7, p8)
    }

    private func deleteAll(table: String, uid: UUID) async throws {
        _ = try await client
            .from(table)
            .delete()
            .eq("user_id", value: uid)
            .execute()
    }

    private func deleteAllFriendships(uid: UUID) async throws {
        _ = try await client
            .from("friendships")
            .delete()
            .or("user_id.eq.\(uid),friend_id.eq.\(uid)")
            .execute()
    }

    private func clearProfileBlobs(uid: UUID) async throws {
        struct Clear: Encodable {
            let leaderboard_data: AnyCodable?
            let custom_exercises: AnyCodable?
        }
        // null both jsonb blobs but keep id, name, username, etc.
        _ = try await client
            .from("profiles")
            .update(Clear(leaderboard_data: nil, custom_exercises: nil))
            .eq("id", value: uid)
            .execute()
    }

    /// Delete the user's account FOR REAL — wipes public-schema data
    /// AND nukes the auth.users row, freeing up the email for future
    /// reuse.
    ///
    /// The auth.users delete can't run from a client session (the row
    /// is protected). Instead we call a Postgres RPC,
    /// `public.delete_current_user()`, which is SECURITY DEFINER:
    /// it runs as `postgres` so it can hit auth.users, but its body
    /// scopes everything to `auth.uid()` — meaning a caller can only
    /// ever delete themselves, never another user. See migration
    /// 2026-05-20-delete-current-user-rpc.sql for the function body.
    func deleteOwnAccount() async throws {
        // Belt-and-suspenders: best-effort wipe of public-schema rows
        // BEFORE calling the RPC. The RPC also wipes them, but doing
        // it from the client side first means if the RPC fails, the
        // user's data is at least mostly gone (recoverable via
        // dashboard re-create rather than a stale account stuck
        // around with workouts in it).
        try? await resetUserData()

        // The RPC drops everything including auth.users. Token is
        // dead after this returns.
        _ = try await client
            .rpc("delete_current_user")
            .execute()

        // Clear ONLY the local session. A normal signOut() uses global
        // scope, which makes a server call to revoke the session — but
        // the user no longer exists, so that call throws and would
        // surface as a false "couldn't delete account" error even
        // though deletion already succeeded. Local scope just wipes the
        // on-device token, no server round-trip, and `try?` swallows
        // any residual error since the account is already gone.
        try? await client.auth.signOut(scope: .local)
    }

    // MARK: - Programme helpers

    /// Fetch the user's currently active programme (one row, `active = true`).
    /// Returns nil if no row matches.
    func fetchActiveProgramme() async throws -> Programme? {
        guard let uid = currentUser?.id else { return nil }
        let rows: [Programme] = try await client
            .from("programmes")
            .select()
            .eq("user_id", value: uid)
            .eq("active", value: true)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Upsert a programme row. Caller is responsible for setting `userId`
    /// and `active` correctly. To switch the active programme, call
    /// `markProgrammeActive(_:)` afterwards which clears `active` on all
    /// other rows.
    func upsertProgramme(_ programme: Programme) async throws {
        _ = try await client
            .from("programmes")
            .upsert(programme)
            .execute()
    }

    /// Make exactly one programme row active for the current user, clearing
    /// `active` on all others. Two-step update so the user always has at
    /// most one active programme.
    func markProgrammeActive(_ programmeId: UUID) async throws {
        guard let uid = currentUser?.id else { return }
        // 1) Deactivate all of the user's other programmes.
        _ = try await client
            .from("programmes")
            .update(["active": false])
            .eq("user_id", value: uid)
            .neq("id", value: programmeId)
            .execute()
        // 2) Activate this one.
        _ = try await client
            .from("programmes")
            .update(["active": true])
            .eq("id", value: programmeId)
            .execute()
    }

    // MARK: - Workout history helpers

    /// Fetch the user's most recent N completed/in-progress sessions,
    /// ordered most-recent first.
    func fetchHistory(limit: Int = 200) async throws -> [WorkoutSession] {
        guard let uid = currentUser?.id else { return [] }
        let rows: [WorkoutSession] = try await client
            .from("sessions")
            .select()
            .eq("user_id", value: uid)
            .order("date", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows
    }

    /// Insert (or upsert by id) a workout session row. The DB table is
    /// named `sessions` (singular) — the React side calls it the same.
    func saveWorkoutSession(_ session: WorkoutSession) async throws {
        _ = try await client
            .from("sessions")
            .upsert(session)
            .execute()
    }

    /// Bulk-insert performed sets. Caller passes in pre-built `PerformedSet`
    /// values with valid `sessionId` and `userId`.
    func savePerformedSets(_ sets: [PerformedSet]) async throws {
        guard !sets.isEmpty else { return }
        _ = try await client
            .from("sets")
            .insert(sets)
            .execute()
    }

    // MARK: - Working weights

    /// Upsert the current user's working-weights map. Keys are canonical
    /// exercise names. The leaderboard-score calculator + PT chat both
    /// read from this table.
    func upsertWorkingWeights(_ weights: [String: Double]) async throws {
        guard let uid = currentUser?.id, !weights.isEmpty else { return }
        struct Row: Encodable {
            let user_id: UUID
            let exercise_name: String
            let weight: Double
        }
        let rows = weights.map { Row(user_id: uid, exercise_name: $0.key, weight: $0.value) }
        _ = try await client
            .from("working_weights")
            .upsert(rows, onConflict: "user_id,exercise_name")
            .execute()
    }

    /// Fetch the current user's working-weights map. Empty if no rows.
    ///
    /// Defensive against duplicate `(user_id, exercise_name)` rows: if the
    /// `working_weights` table is missing its composite UNIQUE constraint
    /// then the upsert clause silently degrades to plain insert, and
    /// `Dictionary(uniqueKeysWithValues:)` would crash on the duplicates.
    /// We use `uniquingKeysWith: max` so duplicates collapse to the
    /// heaviest entry — same semantic the constraint would have enforced.
    func fetchWorkingWeights() async throws -> [String: Double] {
        guard let uid = currentUser?.id else { return [:] }
        struct Row: Decodable {
            let exerciseName: String
            let weight: Double
            enum CodingKeys: String, CodingKey {
                case exerciseName = "exercise_name"
                case weight
            }
        }
        let rows: [Row] = try await client
            .from("working_weights")
            .select("exercise_name, weight")
            .eq("user_id", value: uid)
            .execute()
            .value
        return Dictionary(rows.map { ($0.exerciseName, $0.weight) },
                          uniquingKeysWith: { current, incoming in
                              max(current, incoming)
                          })
    }

    /// Fetch all performed sets for the current user — used by Progress tab
    /// lift cards and the muscle-page detail view. Optionally limit by
    /// exercise name for the single-lift drill-down.
    func fetchAllSets(exerciseName: String? = nil,
                      limit: Int = 1000) async throws -> [PerformedSet] {
        guard let uid = currentUser?.id else { return [] }
        var query = client
            .from("sets")
            .select()
            .eq("user_id", value: uid)
        if let name = exerciseName {
            query = query.eq("exercise_name", value: name)
        }
        let rows: [PerformedSet] = try await query
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows
    }
}
