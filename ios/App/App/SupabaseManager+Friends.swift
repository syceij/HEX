import Foundation
import Supabase

/// Friend / activity / invite-link helpers. Mirrors the back half of
/// `src/lib/db.js`. Each method reads/writes one Supabase table directly.
extension SupabaseManager {

    // MARK: - Friendships row decoder

    /// Bare friendship row used inside the friends/pending queries.
    private struct FriendshipRow: Decodable {
        let id: UUID
        let userId: UUID
        let friendId: UUID
        enum CodingKeys: String, CodingKey {
            case id
            case userId   = "user_id"
            case friendId = "friend_id"
        }
    }

    // MARK: - Friend list

    /// Mirror of `loadFriends(userId)` — returns the OTHER side of every
    /// accepted friendship, joined with the profiles table so we have name,
    /// username, avatar, and cached leaderboard data.
    func fetchFriends() async throws -> [FriendListEntry] {
        guard let uid = currentUser?.id else { return [] }
        let rows: [FriendshipRow] = try await client
            .from("friendships")
            .select("id, user_id, friend_id")
            .or("user_id.eq.\(uid),friend_id.eq.\(uid)")
            .eq("status", value: "accepted")
            .execute()
            .value
        let friendIds: [UUID] = rows.map { $0.userId == uid ? $0.friendId : $0.userId }
        guard !friendIds.isEmpty else { return [] }
        let profiles: [FriendListEntry] = try await client
            .from("profiles")
            .select("id, name, username, leaderboard_data, avatar_url")
            .in("id", values: friendIds)
            .execute()
            .value
        return profiles
    }

    // MARK: - Pending requests

    /// Mirror of `loadPendingRequests(userId)` — only returns rows where
    /// the current user is the recipient (incoming requests).
    func fetchPendingRequests() async throws -> [PendingRequest] {
        guard let uid = currentUser?.id else { return [] }
        let rows: [FriendshipRow] = try await client
            .from("friendships")
            .select("id, user_id, friend_id")
            .or("user_id.eq.\(uid),friend_id.eq.\(uid)")
            .eq("status", value: "pending")
            .execute()
            .value
        // Keep only INCOMING — where current user is the friend (recipient)
        let incoming = rows.filter { $0.friendId == uid }
        let senderIds = incoming.map(\.userId)
        guard !senderIds.isEmpty else { return [] }
        let senders: [UserSearchResult] = try await client
            .from("profiles")
            .select("id, name, username, avatar_url")
            .in("id", values: senderIds)
            .execute()
            .value
        let profMap = Dictionary(uniqueKeysWithValues: senders.map { ($0.id, $0) })
        return incoming.map { row in
            let p = profMap[row.userId]
            return PendingRequest(
                friendshipId: row.id,
                userId:       row.userId,
                name:         p?.name ?? "Unknown",
                username:     p?.username,
                avatarURL:    p?.avatarURL
            )
        }
    }

    // MARK: - Send / respond / remove

    /// Send a friend request (status = pending).
    func sendFriendRequest(toUserId friendId: UUID) async throws {
        guard let uid = currentUser?.id else { return }
        struct Payload: Encodable {
            let user_id: UUID
            let friend_id: UUID
            let status: String
        }
        _ = try await client
            .from("friendships")
            .insert(Payload(user_id: uid, friend_id: friendId, status: "pending"))
            .execute()
    }

    /// Accept (status → "accepted") or decline (delete the row).
    func respondFriendRequest(friendshipId: UUID, accept: Bool) async throws {
        if accept {
            _ = try await client
                .from("friendships")
                .update(["status": "accepted"])
                .eq("id", value: friendshipId)
                .execute()
        } else {
            _ = try await client
                .from("friendships")
                .delete()
                .eq("id", value: friendshipId)
                .execute()
        }
    }

    /// Delete both directions of an accepted friendship.
    func removeFriend(friendId: UUID) async throws {
        guard let uid = currentUser?.id else { return }
        _ = try await client
            .from("friendships")
            .delete()
            .or("and(user_id.eq.\(uid),friend_id.eq.\(friendId)),and(user_id.eq.\(friendId),friend_id.eq.\(uid))")
            .execute()
    }

    // MARK: - User search

    /// Search profiles by username substring (case-insensitive). Excludes self.
    func searchUsers(query: String) async throws -> [UserSearchResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let uid = currentUser?.id else { return [] }
        let rows: [UserSearchResult] = try await client
            .from("profiles")
            .select("id, name, username, avatar_url")
            .ilike("username", pattern: "%\(q)%")
            .neq("id", value: uid)
            .limit(10)
            .execute()
            .value
        return rows
    }

    // MARK: - Invite links

    /// Generate a fresh 8-char invite code valid for 48h.
    @discardableResult
    func createInviteLink() async throws -> InviteLink {
        guard let uid = currentUser?.id else {
            throw NSError(domain: "createInviteLink", code: 401)
        }
        let code = String(UUID().uuidString.replacingOccurrences(of: "-", with: "")
                          .prefix(8)).uppercased()
        let expires = Date().addingTimeInterval(48 * 3600)
        struct Payload: Encodable {
            let user_id: UUID
            let code: String
            let expires_at: Date
        }
        let row: InviteLink = try await client
            .from("invite_links")
            .insert(Payload(user_id: uid, code: code, expires_at: expires))
            .select()
            .single()
            .execute()
            .value
        return row
    }

    /// Result returned by acceptInvite — used by the inviter-name toast.
    struct AcceptInviteResult {
        let inviterName: String
    }

    /// Accept an invite link — creates the accepted friendship and marks
    /// the link used. Throws on invalid, expired, or self-invite.
    func acceptInvite(code: String) async throws -> AcceptInviteResult {
        guard let uid = currentUser?.id else {
            throw NSError(domain: "acceptInvite", code: 401)
        }
        let rows: [InviteLink] = try await client
            .from("invite_links")
            .select()
            .eq("code", value: code)
            .eq("used", value: false)
            .limit(1)
            .execute()
            .value
        guard let inv = rows.first else { throw InviteError.invalid }
        if let exp = inv.expiresAt, exp < Date() { throw InviteError.expired }
        if inv.userId == uid { throw InviteError.selfInvite }

        struct FriendshipPayload: Encodable {
            let user_id: UUID
            let friend_id: UUID
            let status: String
        }
        // Ignore duplicate-key violations — we'll just update the link state.
        do {
            _ = try await client
                .from("friendships")
                .insert(FriendshipPayload(user_id: inv.userId, friend_id: uid,
                                          status: "accepted"))
                .execute()
        } catch {
            let s = (error as NSError).localizedDescription
            if !s.contains("23505") && !s.contains("duplicate") { throw error }
        }

        _ = try await client
            .from("invite_links")
            .update(["used": true])
            .eq("id", value: inv.id)
            .execute()

        struct NameRow: Decodable { let name: String? }
        let inviter: [NameRow] = try await client
            .from("profiles")
            .select("name")
            .eq("id", value: inv.userId)
            .limit(1)
            .execute()
            .value
        return AcceptInviteResult(inviterName: inviter.first?.name ?? "Someone")
    }

    enum InviteError: LocalizedError {
        case invalid, expired, selfInvite
        var errorDescription: String? {
            switch self {
            case .invalid:    return "Invite link is invalid."
            case .expired:    return "Invite link has expired."
            case .selfInvite: return "You can't accept your own invite."
            }
        }
    }

    // MARK: - Activity feed

    /// Best-effort activity insert with idempotent retry.
    ///
    /// Was previously a single fire-and-forget insert whose failure was
    /// swallowed — so a transient network blip in the ~2s after a session
    /// save could silently drop the feed row while the workout itself
    /// saved fine. One such drop was seen in production (a `sessions` row
    /// with no matching `activity_feed` row), which made that session
    /// invisible in every friend's Recent Activity.
    ///
    /// Hardening:
    ///   • The row `id` is generated ONCE on the client, then we retry up
    ///     to 3× with backoff. Each attempt is an UPSERT keyed on `id`, so
    ///     if an earlier attempt actually committed server-side but the
    ///     client never saw the ack (timeout), the retry rewrites the same
    ///     row rather than creating a duplicate.
    ///   • Still never throws: the social-feed echo must never block or
    ///     fail a workout save.
    ///   • The happy path adds ZERO delay — attempt 1 has no backoff and
    ///     returns immediately on success; the sleeps only run after a
    ///     failed attempt.
    ///
    /// Returns true once the row is known to be persisted, false if every
    /// attempt failed (caller should not treat that as a save failure).
    @discardableResult
    func insertActivity(type: String, data: [String: Any]) async -> Bool {
        guard let uid = currentUser?.id else { return false }
        let encoded = data.mapValues { AnyCodable($0) }
        struct Payload: Encodable {
            let id: UUID
            let user_id: UUID
            let type: String
            let data: [String: AnyCodable]
        }
        let payload = Payload(id: UUID(), user_id: uid, type: type, data: encoded)
        // Backoff before each attempt, in nanoseconds: 0s, 0.8s, 2.0s.
        let backoffs: [UInt64] = [0, 800_000_000, 2_000_000_000]
        for (attempt, delay) in backoffs.enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            do {
                _ = try await client
                    .from("activity_feed")
                    .upsert(payload, onConflict: "id")
                    .execute()
                return true
            } catch {
                print("[insertActivity] attempt \(attempt + 1)/\(backoffs.count) failed:", error)
            }
        }
        print("[insertActivity] all attempts failed (non-fatal) — feed row not written")
        return false
    }

    /// Load recent activity for the user + their friends. Limit 20 newest.
    func fetchActivityFeed(friendIds: [UUID]) async throws -> [ActivityRow] {
        guard let uid = currentUser?.id else { return [] }
        let ids = [uid] + friendIds
        let rows: [ActivityFeedItem] = try await client
            .from("activity_feed")
            .select()
            .in("user_id", values: ids)
            .order("created_at", ascending: false)
            .limit(20)
            .execute()
            .value
        guard !rows.isEmpty else { return [] }
        // Profile join (in-memory) for displayed names + avatars
        let profiles: [UserSearchResult] = try await client
            .from("profiles")
            .select("id, name, username, avatar_url")
            .in("id", values: ids)
            .execute()
            .value
        let pmap = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return rows.map { r in
            let p = pmap[r.userId]
            return ActivityRow(
                id:              r.id,
                userId:          r.userId,
                type:            r.type,
                createdAt:       r.createdAt ?? Date(),
                data:            r.data,
                profileName:     p?.name,
                profileUsername: p?.username,
                avatarURL:       p?.avatarURL
            )
        }
    }

    // MARK: - Friend profile (read-only)

    /// Loads `id, name, username, avatar_url, privacy_settings,
    /// leaderboard_data` for the friend profile page. Leaderboard
    /// data is included so the points hero card reads the same
    /// values shown on the friends-list leaderboard, AND so users
    /// opening a friend's profile from a LEAGUE row see real
    /// points (previously the league-row tap passed a synthetic
    /// FriendListEntry with `leaderboardData: nil`, which made the
    /// card read 0 even when the user had a real score).
    struct FriendProfileRow: Decodable {
        let id: UUID
        var name: String?
        var username: String?
        var avatarURL: String?
        var privacySettings: [String: AnyCodable]?
        var leaderboardData: LeaderboardData?
        /// Earned trophies (same shape as `Profile.badges`). nil when
        /// the friend has no badges yet — treat as [] at the call site.
        var badges: [EarnedBadge]?
        enum CodingKeys: String, CodingKey {
            case id, name, username, badges
            case avatarURL       = "avatar_url"
            case privacySettings = "privacy_settings"
            case leaderboardData = "leaderboard_data"
        }
    }

    func fetchFriendProfile(friendId: UUID) async throws -> FriendProfileRow? {
        let rows: [FriendProfileRow] = try await client
            .from("profiles")
            .select("id, name, username, avatar_url, privacy_settings, leaderboard_data, badges")
            .eq("id", value: friendId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// Last N sessions for a friend, newest first. Pulls only what the
    /// FriendProfilePage uses (no individual sets).
    func fetchFriendSessions(friendId: UUID, limit: Int = 10) async throws -> [FriendSession] {
        let rows: [WorkoutSession] = try await client
            .from("sessions")
            .select()
            .eq("user_id", value: friendId)
            .order("date", ascending: false)
            .limit(limit)
            .execute()
            .value
        return rows.map { r in
            FriendSession(
                id:        r.id,
                date:      r.date,
                name:      r.name,
                exercises: r.data?.exercises ?? []
            )
        }
    }

    /// Friend's working weights map (exercise → kg). Empty if column missing.
    func fetchFriendWeights(friendId: UUID) async throws -> [String: Double] {
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
            .eq("user_id", value: friendId)
            .execute()
            .value
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.exerciseName, $0.weight) })
    }

    /// Fetch a friend's currently active programme (id, name, data).
    /// Returns nil if they have no active programme. Caller is
    /// expected to gate this on the friend's privacy_settings — the
    /// query itself is unconditional because RLS on the `programmes`
    /// table is the authoritative check.
    func fetchFriendActiveProgramme(friendId: UUID) async throws -> Programme? {
        struct Row: Decodable {
            let id: UUID
            let name: String
            let data: ProgrammeData?
            let active: Bool?
        }
        let rows: [Row] = try await client
            .from("programmes")
            .select("id, name, data, active")
            .eq("user_id", value: friendId)
            .eq("active", value: true)
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        guard let first = rows.first else { return nil }
        return Programme(
            id: first.id,
            userId: friendId,
            name: first.name,
            active: first.active ?? true,
            data: first.data,
            createdAt: nil
        )
    }

    /// Fetch the user's custom exercises (stored as a JSON array on
    /// `profiles.custom_exercises`).
    func fetchOwnCustomExercises() async throws -> [CustomExercise] {
        guard let uid = currentUser?.id else { return [] }
        struct Row: Decodable {
            let customExercises: [CustomExercise]?
            enum CodingKeys: String, CodingKey {
                case customExercises = "custom_exercises"
            }
        }
        let rows: [Row] = try await client
            .from("profiles")
            .select("custom_exercises")
            .eq("id", value: uid)
            .limit(1)
            .execute()
            .value
        return rows.first?.customExercises ?? []
    }

    /// Persist the full custom-exercises array (replace-all semantics — the
    /// React side uses the same pattern so two clients editing concurrently
    /// converge predictably).
    func saveCustomExercises(_ exercises: [CustomExercise]) async throws {
        guard let uid = currentUser?.id else { return }
        struct Patch: Encodable { let custom_exercises: [CustomExercise] }
        _ = try await client
            .from("profiles")
            .update(Patch(custom_exercises: exercises))
            .eq("id", value: uid)
            .execute()
    }

    /// Fetch just the leaderboard_data jsonb column for the current user.
    /// Returns nil if no row or no data.
    func fetchOwnLeaderboardData() async throws -> LeaderboardData? {
        guard let uid = currentUser?.id else { return nil }
        struct Row: Decodable {
            let leaderboardData: LeaderboardData?
            enum CodingKeys: String, CodingKey {
                case leaderboardData = "leaderboard_data"
            }
        }
        let rows: [Row] = try await client
            .from("profiles")
            .select("leaderboard_data")
            .eq("id", value: uid)
            .limit(1)
            .execute()
            .value
        return rows.first?.leaderboardData
    }

    // MARK: - Leaderboard score

    /// Compute the current user's leaderboard score and persist it to
    /// `profiles.leaderboard_data`. Mirrors `updateLeaderboardScore` in
    /// src/lib/db.js. Returns the new score, or nil on error.
    @discardableResult
    func recalculateAndStoreLeaderboardScore() async -> LeaderboardData? {
        guard let uid = currentUser?.id else { return nil }
        let data = await calculateLeaderboardScore(userId: uid)
        guard let data = data else { return nil }
        do {
            // Encode the score blob so we can wrap it in an update.
            let blob = try JSONEncoder().encode(data)
            let json = try JSONSerialization.jsonObject(with: blob) as? [String: Any] ?? [:]
            let encoded = json.mapValues { AnyCodable($0) }
            struct UpdatePayload: Encodable {
                let leaderboard_data: [String: AnyCodable]
            }
            _ = try await client
                .from("profiles")
                .update(UpdatePayload(leaderboard_data: encoded))
                .eq("id", value: uid)
                .execute()

            // Also snapshot this month into leaderboard_history so the
            // Monthly History timeline accumulates. Best-effort — a
            // failed snapshot must never block the score update.
            await snapshotMonthlyScore(data)

            return data
        } catch {
            print("[updateLeaderboardScore] failed:", error)
            return nil
        }
    }

    // MARK: - Monthly history

    /// One month's snapshot, read from leaderboard_history. Used by the
    /// Profile "Monthly History" sheet + friend profiles.
    struct MonthlyResult: Identifiable, Hashable {
        var month: String          // "YYYY-MM"
        var score: Int
        var setsCompleted: Int
        var setsProgrammed: Int
        var improvementPct: Int
        var id: String { month }
    }

    /// Upsert the current month into leaderboard_history via the
    /// SECURITY DEFINER RPC. Best-effort; errors are logged only.
    func snapshotMonthlyScore(_ data: LeaderboardData) async {
        struct Params: Encodable {
            let p_month: String
            let p_score: Int
            let p_sets_completed: Int
            let p_sets_programmed: Int
            let p_improvement_pct: Int
        }
        do {
            _ = try await client
                .rpc("snapshot_leaderboard_month", params: Params(
                    p_month:           data.month,
                    p_score:           data.score,
                    p_sets_completed:  data.setsCompleted,
                    p_sets_programmed: data.setsProgrammed,
                    p_improvement_pct: data.improvementPct
                ))
                .execute()
        } catch {
            print("[snapshotMonthlyScore] failed (non-fatal):", error)
        }
    }

    /// Fetch a user's monthly history, newest month first. Works for the
    /// current user OR any friend (read policy is open to authenticated).
    func fetchLeaderboardHistory(userId: UUID) async throws -> [MonthlyResult] {
        struct Row: Decodable {
            let month: String
            let score: Int
            let sets_completed: Int
            let sets_programmed: Int
            let improvement_pct: Int
        }
        let rows: [Row] = try await client
            .from("leaderboard_history")
            .select("month, score, sets_completed, sets_programmed, improvement_pct")
            .eq("user_id", value: userId)
            .order("month", ascending: false)
            .execute()
            .value
        return rows.map {
            MonthlyResult(
                month:          $0.month,
                score:          $0.score,
                setsCompleted:  $0.sets_completed,
                setsProgrammed: $0.sets_programmed,
                improvementPct: $0.improvement_pct
            )
        }
    }

    /// Internal helper — does the full calculation. Doesn't write anything.
    private func calculateLeaderboardScore(userId: UUID) async -> LeaderboardData? {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: now)
        guard let year = comps.year, let monthN = comps.month else { return nil }
        let monthKey = String(format: "%04d-%02d", year, monthN)
        let firstOfMonth = cal.date(from: DateComponents(year: year, month: monthN, day: 1)) ?? now

        // ── Pull all required tables in parallel ──
        struct EmptyId: Decodable { let id: UUID }
        struct WeightRow: Decodable {
            let exerciseName: String
            let weight: Double?
            enum CodingKeys: String, CodingKey {
                case exerciseName = "exercise_name"
                case weight
            }
        }
        struct ProgrammeShell: Decodable {
            let data: ProgrammeData?
        }
        struct SetRow: Decodable {
            let exerciseName: String?
            let reps: AnyCodable?
            let weight: Double?
            enum CodingKeys: String, CodingKey {
                case exerciseName = "exercise_name"
                case reps, weight
            }
        }

        async let completedSetsT: [EmptyId]    = (try? client
            .from("sets")
            .select("id")
            .eq("user_id", value: userId)
            .eq("completed", value: true)
            .gte("created_at", value: ISO8601DateFormatter().string(from: firstOfMonth))
            .execute().value) ?? []
        async let weightsT: [WeightRow]        = (try? client
            .from("working_weights")
            .select("exercise_name, weight")
            .eq("user_id", value: userId)
            .execute().value) ?? []
        async let programmesT: [ProgrammeShell] = (try? client
            .from("programmes")
            .select("data")
            .eq("user_id", value: userId)
            .eq("active", value: true)
            .order("created_at", ascending: false)
            .limit(1)
            .execute().value) ?? []
        async let allSetsT: [SetRow]           = (try? client
            .from("sets")
            .select("exercise_name, reps, weight")
            .eq("user_id", value: userId)
            .order("created_at", ascending: true)
            .execute().value) ?? []

        let completedSets = await completedSetsT
        let weights       = await weightsT
        let programmeArr  = await programmesT
        let allSets       = await allSetsT

        let setsCompleted = completedSets.count

        // Monthly-fixed consistency target — user's idea: the
        // denominator is the user's programmed sets PER MONTH, not
        // scaled to weeks elapsed. So hitting your monthly quota
        // by day 20 = 100%, hitting it on day 30 = 100% — same
        // bar. Two big benefits over the prior time-scaled formula:
        //   1. Eliminates the "Sultan-with-no-programme beats
        //      Ahmed-with-big-programme" exploit: small programme
        //      cannot beat large programme just by completing
        //      a higher % of a smaller quota — the % is what's
        //      tracked, and both top out at 100%.
        //   2. The bar is stable through the month — users see
        //      a fixed target instead of one that moves daily.
        //
        // A "monthly programme" is treated as `weeklySets × 4`,
        // regardless of how many calendar weeks happen to fall in
        // the current month. This keeps the math simple, matches
        // the user's intuition ("a month of training"), and avoids
        // edge cases like 5-week months making the bar artificially
        // higher than 4-week months.
        let monthlySetsPlanned: Int = {
            guard let progData = programmeArr.first?.data,
                  let week = progData.weeks.first
            else { return 0 }
            var perWeek = 0
            for s in week.sessions {
                for ex in s.exercises {
                    perWeek += max(ex.sets, 1)
                }
            }
            return perWeek * 4
        }()

        let setsProgrammed = monthlySetsPlanned

        // No active programme → user can't open a session in the
        // app, so they shouldn't score anything either. The prior
        // formula's "setsCompleted × 1.25" fallback let no-programme
        // users coast at an inflated ~80% consistency — explicitly
        // gone now. 0% consistency for no-programme is fair: the
        // app makes building a programme a prerequisite for training,
        // so the points system should mirror that.
        let consistency: Double = setsProgrammed > 0
            ? (Double(setsCompleted) / Double(setsProgrammed)) * 100.0
            : 0.0

        // ── Improvement per tracked exercise ──
        func parseReps(_ v: Any?) -> Int {
            if let i = v as? Int    { return i }
            if let d = v as? Double { return Int(d) }
            if let s = v as? String {
                let first = s.split(separator: "-").first.map(String.init) ?? s
                return Int(first.trimmingCharacters(in: .whitespaces)) ?? 8
            }
            return 8
        }

        var grouped: [String: [(reps: Int, weight: Double)]] = [:]
        for r in allSets {
            guard let name = r.exerciseName?.lowercased().trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }
            grouped[name, default: []].append(
                (reps: parseReps(r.reps?.value), weight: r.weight ?? 0)
            )
        }
        var totalImprovement = 0.0
        var exCount = 0
        for w in weights {
            let key = w.exerciseName.lowercased().trimmingCharacters(in: .whitespaces)
            guard let rows = grouped[key], rows.count >= 2 else { continue }
            let firstVol   = Double(rows.first!.reps)  * rows.first!.weight
            let currentVol = Double(rows.last!.reps)   * rows.last!.weight
            if firstVol > 0 {
                let imp = ((currentVol - firstVol) / firstVol) * 100.0
                totalImprovement += max(0, imp)
                exCount += 1
            }
        }
        let improvement: Double = exCount > 0 ? totalImprovement / Double(exCount) : 0

        let final = Int(((consistency * 0.7) + (improvement * 0.3)).rounded())
        return LeaderboardData(
            score:          final,
            setsCompleted:  setsCompleted,
            setsProgrammed: setsProgrammed,
            improvementPct: Int(improvement.rounded()),
            month:          monthKey,
            updatedAt:      ISO8601DateFormatter().string(from: Date())
        )
    }
}
