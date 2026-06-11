import Foundation

// MARK: - Profile

/// Mirrors the `profiles` table in Supabase.
/// One slot in the user's "tracked lifts" carousel on the Progress tab.
/// Mirrors React's `{ name, key }` object stored inside the
/// `profiles.tracked_lifts` jsonb array — null entries indicate an
/// empty slot. We keep both apps writing the same shape so a slot
/// chosen on iOS shows up on the web and vice versa.
struct TrackedLift: Codable, Hashable {
    var name: String
    var key: String?

    init(name: String, key: String? = nil) {
        self.name = name
        self.key = key
    }

    enum CodingKeys: String, CodingKey { case name, key }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.key  = try? c.decode(String.self, forKey: .key)
    }
}

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String?
    var username: String?
    var email: String?
    var language: String?           // "en" | "ar"
    /// Up to 4 user-pinned tracked lifts. Slot order matters; `nil`
    /// preserves an empty slot rather than collapsing the list. Decoder
    /// also accepts the legacy `[String]` shape iOS briefly wrote before
    /// the schema was reconciled with React's `[{name,key}]`.
    var trackedLifts: [TrackedLift?]?
    var trackedMuscles: [String]?   // 6 muscle groups
    var avatarURL: String?
    var createdAt: Date?
    /// Earned trophies, persisted as a jsonb array on the row
    /// (see migration 2026-05-20-profiles-badges-column.sql). nil
    /// when the column is empty/null — treat as []. Awarding logic
    /// that appends to this array ships in a later milestone.
    var badges: [EarnedBadge]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case username
        case email
        case language
        case trackedLifts   = "tracked_lifts"
        case trackedMuscles = "tracked_muscles"
        case avatarURL      = "avatar_url"
        case createdAt      = "created_at"
        case badges
    }

    init(id: UUID, name: String?, username: String?, email: String?,
         language: String?, trackedLifts: [TrackedLift?]?, trackedMuscles: [String]?,
         avatarURL: String?, createdAt: Date?, badges: [EarnedBadge]? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.email = email
        self.language = language
        self.trackedLifts = trackedLifts
        self.trackedMuscles = trackedMuscles
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.badges = badges
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id             = try c.decode(UUID.self, forKey: .id)
        // All other fields use `try?` so a single malformed column doesn't
        // throw the whole decode — the user still gets a partial Profile.
        self.name           = try? c.decode(String.self, forKey: .name)
        self.username       = try? c.decode(String.self, forKey: .username)
        self.email          = try? c.decode(String.self, forKey: .email)
        self.language       = try? c.decode(String.self, forKey: .language)
        self.trackedLifts   = Self.decodeTrackedLifts(from: c)
        self.trackedMuscles = try? c.decode([String].self, forKey: .trackedMuscles)
        self.avatarURL      = try? c.decode(String.self, forKey: .avatarURL)
        self.createdAt      = LenientDate.optional(c, .createdAt)
        self.badges         = try? c.decode([EarnedBadge].self, forKey: .badges)
    }

    /// Tolerant decoder for `tracked_lifts` — accepts both the canonical
    /// React shape `[{name, key}, null, ...]` and the legacy iOS shape
    /// `["Bench Press", "Squat"]` so old rows don't blank out the slots.
    private static func decodeTrackedLifts(
        from c: KeyedDecodingContainer<CodingKeys>
    ) -> [TrackedLift?]? {
        if let arr = try? c.decode([TrackedLift?].self, forKey: .trackedLifts) {
            return arr
        }
        if let names = try? c.decode([String].self, forKey: .trackedLifts) {
            return names.map { TrackedLift(name: $0) }
        }
        return nil
    }
}

// MARK: - Programme

/// Programme metadata row in `programmes` table.
struct Programme: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var name: String
    var active: Bool
    var data: ProgrammeData?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId    = "user_id"
        case name
        case active
        case data
        case createdAt = "created_at"
    }

    init(id: UUID, userId: UUID, name: String, active: Bool,
         data: ProgrammeData?, createdAt: Date?) {
        self.id = id; self.userId = userId; self.name = name
        self.active = active; self.data = data; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id        = try c.decode(UUID.self,     forKey: .id)
        self.userId    = try c.decode(UUID.self,     forKey: .userId)
        self.name      = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.active    = (try? c.decode(Bool.self,   forKey: .active)) ?? false
        self.data      = try? c.decode(ProgrammeData.self, forKey: .data)
        self.createdAt = LenientDate.optional(c, .createdAt)
    }
}

/// Programme content (stored as JSONB in `programmes.data`).
///
/// Decoded from THREE possible shapes that may exist in the database:
///   • iOS-built:   `{name, totalWeeks, weeks: [...]}`
///   • React auto:  `{mode: 'auto', programme: [session1, session2, ...]}`
///                  (flat session array, no week wrapper)
///   • React imp:   `{mode: 'imported', importedProgramme: {name, weeks: [...]}, ...}`
///
/// All three normalise to the same in-memory shape (`{name, totalWeeks, weeks}`)
/// so the rest of the app can treat them uniformly.
struct ProgrammeData: Codable, Hashable {
    var name: String
    var totalWeeks: Int
    var weeks: [ProgrammeWeek]

    init(name: String, totalWeeks: Int, weeks: [ProgrammeWeek]) {
        self.name = name
        self.totalWeeks = totalWeeks
        self.weeks = weeks
    }

    enum CodingKeys: String, CodingKey {
        case name, totalWeeks, weeks
        case mode, programme, importedProgramme
    }
    enum ImportedKeys: String, CodingKey {
        case name, weeks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Shape 1 — iOS-built: top-level `weeks`. Easiest path.
        if let w = try? c.decode([ProgrammeWeek].self, forKey: .weeks), !w.isEmpty {
            self.weeks = w
            self.name = (try? c.decode(String.self, forKey: .name)) ?? "Programme"
            self.totalWeeks = (try? c.decode(Int.self, forKey: .totalWeeks)) ?? max(w.count, 1)
            return
        }

        // Shape 2 — React imported: nested `importedProgramme.weeks`.
        if let imported = try? c.nestedContainer(keyedBy: ImportedKeys.self,
                                                  forKey: .importedProgramme) {
            let w = (try? imported.decode([ProgrammeWeek].self, forKey: .weeks)) ?? []
            self.weeks = w
            self.name = (try? imported.decode(String.self, forKey: .name)) ?? "Imported Programme"
            self.totalWeeks = max(w.count, 1)
            return
        }

        // Shape 3 — React auto: flat `programme: [session, session, ...]`.
        // Wrap the sessions into a single 1-week container.
        if let sessions = try? c.decode([ProgrammeSession].self, forKey: .programme) {
            self.weeks = [ProgrammeWeek(weekNumber: 1, sessions: sessions)]
            let mode = (try? c.decode(String.self, forKey: .mode)) ?? "Programme"
            self.name = mode.capitalized
            self.totalWeeks = 1
            return
        }

        // Fallback — empty programme so the row at least decodes.
        self.name = "Programme"
        self.totalWeeks = 1
        self.weeks = []
    }

    // Re-implement encode so the synthesized version isn't suppressed.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name,       forKey: .name)
        try c.encode(totalWeeks, forKey: .totalWeeks)
        try c.encode(weeks,      forKey: .weeks)
    }
}

struct ProgrammeWeek: Codable, Hashable {
    var weekNumber: Int
    var sessions: [ProgrammeSession]
    /// Optional human-readable label for the week (e.g. `"Block 1 · base
    /// volume · week 1"`). React uses this for the week pill text on
    /// HomeTab — falls back to `"W{weekNumber}"` when absent.
    var label: String?

    init(weekNumber: Int, sessions: [ProgrammeSession], label: String? = nil) {
        self.weekNumber = weekNumber
        self.sessions = sessions
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case weekNumber, sessions, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.weekNumber = (try? c.decode(Int.self, forKey: .weekNumber)) ?? 1
        self.sessions   = (try? c.decode([ProgrammeSession].self, forKey: .sessions)) ?? []
        self.label      = try? c.decode(String.self, forKey: .label)
    }
}

struct ProgrammeSession: Codable, Hashable, Identifiable {
    var id: UUID { UUID() }
    /// "mon" | "tue" | ... — empty string when the programme came from
    /// React's auto flow (which doesn't carry weekday slugs).
    var day: String
    var name: String
    var exercises: [Exercise]
    /// Optional sub-header (e.g. "Power" / "Hypertrophy" / "Recovery").
    /// Mirrors the JS `session.focus` field. Edited via ProgrammePage.
    var focus: String?
    /// Optional block label this session falls under (e.g. "Block 1" or
    /// "Week 1-4 — Volume"). Mirrors the JS `session.block` field.
    var block: String?
    /// True for explicit rest-day entries in React's imported shape
    /// (`{day: "tue", isRest: true}`). When true, the session has no
    /// name/exercises and HomeView/TrainView treat it as a rest day.
    var isRest: Bool

    init(day: String, name: String, exercises: [Exercise],
         focus: String? = nil, block: String? = nil, isRest: Bool = false) {
        self.day = day
        self.name = name
        self.exercises = exercises
        self.focus = focus
        self.block = block
        self.isRest = isRest
    }

    enum CodingKeys: String, CodingKey {
        case day, name, exercises, focus, block, isRest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.day       = (try? c.decode(String.self, forKey: .day)) ?? ""
        self.name      = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.exercises = (try? c.decode([Exercise].self, forKey: .exercises)) ?? []
        self.focus     = try? c.decode(String.self, forKey: .focus)
        self.block     = try? c.decode(String.self, forKey: .block)
        self.isRest    = (try? c.decode(Bool.self, forKey: .isRest)) ?? false
    }
}

/// One exercise inside a programme session.
///
/// React stores exercises with polymorphic field types — for example
/// `weight` can be a `Number`, the string `"BW"`, the string `"light"`,
/// `null`, or absent entirely; `reps` can be a string ("8-10") or a
/// raw number (8). A strict Codable synthesis throws on every row and
/// the whole exercises array decodes as `[]`, which is exactly the
/// "0 exercises" bug we hit. This custom decoder absorbs all the
/// shapes that occur across React's `programme.js`, `importHelpers.js`,
/// `ManualProgrammeBuilder.jsx`, and `ExercisePickerSheet.jsx` paths.
struct Exercise: Codable, Hashable, Identifiable {
    /// Library or import key. Examples: `bench_press`, `imported_2_squat`,
    /// `custom_my_lift`. React's ManualBuilder may emit `null` — we then
    /// synthesize a slug from `name` so SwiftUI lists have a stable identity.
    var key: String
    var name: String
    /// `"compound"` | `"accessory"` | other (historical) | nil.
    var tag: String?
    /// Number of sets to perform. Defaults to 3.
    var sets: Int
    /// Rep prescription, e.g. `"8-10"`. Coerced to String even when the
    /// JSON wrote a raw number.
    var reps: String
    /// Working weight in kg. `nil` for bodyweight, unset, or non-numeric
    /// labels — see `weightLabel` for the original `"BW"` / `"light"` text.
    var weight: Double?
    /// Display label when `weight` is non-numeric. Values: `"BW"`, `"light"`,
    /// or nil. Mirrors React's `weightLabel` field.
    var weightLabel: String?
    /// RPE descriptor, e.g. `"7-8"`. Empty / missing → nil.
    var rpe: String?
    /// Free-form notes. Empty / missing → nil.
    var notes: String?
    /// True for bodyweight exercises. Defaults to false.
    var bodyweight: Bool
    /// Primary muscle slug (`"chest"`, `"back"`, `"biceps"`, ...). Only
    /// auto-builder + custom exercises set this; imported / manual omit.
    var muscle: String?
    /// Progression flag toggled by the React PT chat. Defaults false.
    var readyToProgress: Bool
    /// `true` for user-created exercises (also have `category`, `equipment`,
    /// and `createdAt` set).
    var isCustom: Bool?
    /// Display category for custom exercises (`"Chest"`, `"Triceps"`, ...).
    var category: String?
    /// Equipment slug (`"barbell"`, `"dumbbell"`, ..., `"custom"`).
    var equipment: String?
    /// ISO timestamp string for custom exercises. Stored as String because
    /// React writes it via `new Date().toISOString()` and never re-parses it.
    var createdAt: String?
    /// Per-exercise rest-timer duration in seconds, persisted into the
    /// programme JSON so iOS and the web see the same choice. `nil` means
    /// "use the default for this exercise's tag" (`RestTimerPresets.defaultSeconds`).
    /// Mirrors React's `ex.restTimer` field set from ProgrammePage.jsx.
    var restTimer: Int?

    /// Stable Identifiable id — uses `key` so SwiftUI lists don't churn
    /// on every re-render (the old `UUID()` getter caused flicker).
    var id: String { key }

    /// Memberwise-style init covering every field with sensible defaults.
    /// Existing call sites that pass `(name:, tag:, sets:, reps:, weight:,
    /// rpe:, notes:)` keep working — the new fields all default.
    init(name: String,
         tag: String? = nil,
         sets: Int = 3,
         reps: String = "8-10",
         weight: Double? = nil,
         rpe: String? = nil,
         notes: String? = nil,
         key: String? = nil,
         weightLabel: String? = nil,
         bodyweight: Bool = false,
         muscle: String? = nil,
         readyToProgress: Bool = false,
         isCustom: Bool? = nil,
         category: String? = nil,
         equipment: String? = nil,
         createdAt: String? = nil,
         restTimer: Int? = nil) {
        self.name            = name
        self.tag             = tag
        self.sets            = sets
        self.reps            = reps
        self.weight          = weight
        self.weightLabel     = weightLabel
        self.rpe             = rpe
        self.notes           = notes
        self.bodyweight      = bodyweight
        self.muscle          = muscle
        self.readyToProgress = readyToProgress
        self.isCustom        = isCustom
        self.category        = category
        self.equipment       = equipment
        self.createdAt       = createdAt
        self.restTimer       = restTimer
        self.key             = key.flatMap { $0.isEmpty ? nil : $0 }
                                ?? Self.slug(from: name)
    }

    /// Slugify a name into a stable id, matching React's custom-exercise
    /// key convention: lowercase, spaces → `_`, drop non-alphanumerics.
    static func slug(from name: String) -> String {
        let lower = name.lowercased()
        let cleaned = lower
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }

    enum CodingKeys: String, CodingKey {
        case name, tag, sets, reps, weight, rpe, notes
        case key, weightLabel, bodyweight, muscle, readyToProgress
        case isCustom, category, equipment, createdAt, restTimer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // name — only field treated as required, but missing → empty string
        // so the row at least decodes (the synthetic key path below still works).
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""

        // sets — JSON may be Int, Double, or numeric String. Default 3.
        if let n = try? c.decode(Int.self, forKey: .sets) {
            self.sets = n
        } else if let d = try? c.decode(Double.self, forKey: .sets) {
            self.sets = Int(d)
        } else if let s = try? c.decode(String.self, forKey: .sets),
                  let n = Int(s.trimmingCharacters(in: .whitespaces)) {
            self.sets = n
        } else {
            self.sets = 3
        }

        // reps — JSON may be String ("8-10") OR Number (8). Coerce to String.
        if let s = try? c.decode(String.self, forKey: .reps) {
            self.reps = s
        } else if let i = try? c.decode(Int.self, forKey: .reps) {
            self.reps = String(i)
        } else if let d = try? c.decode(Double.self, forKey: .reps) {
            self.reps = d.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(d)) : String(d)
        } else {
            self.reps = "8-10"
        }

        // weight — Number → kg; String ("BW" | "light" | "5kg" | ...) →
        // try numeric parse first, otherwise treat as a label; null/absent → nil.
        var parsedWeight: Double? = nil
        var parsedWeightLabel: String? = nil
        if let d = try? c.decode(Double.self, forKey: .weight) {
            parsedWeight = d
        } else if let i = try? c.decode(Int.self, forKey: .weight) {
            parsedWeight = Double(i)
        } else if let s = try? c.decode(String.self, forKey: .weight) {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if let n = Double(trimmed) {
                parsedWeight = n
            } else if !trimmed.isEmpty,
                      trimmed.lowercased() != "undefined",
                      trimmed.lowercased() != "null" {
                parsedWeightLabel = trimmed
            }
        }
        // An explicit `weightLabel` field on the JSON wins over the inferred one
        // (covers React rows where `weight: 0, weightLabel: "BW"`).
        if let explicit = try? c.decode(String.self, forKey: .weightLabel),
           !explicit.isEmpty,
           explicit.lowercased() != "undefined",
           explicit.lowercased() != "null" {
            parsedWeightLabel = explicit
        }
        self.weight      = parsedWeight
        self.weightLabel = parsedWeightLabel

        self.tag       = try? c.decode(String.self, forKey: .tag)
        self.rpe       = try? c.decode(String.self, forKey: .rpe)
        self.notes     = try? c.decode(String.self, forKey: .notes)
        self.muscle    = try? c.decode(String.self, forKey: .muscle)
        self.category  = try? c.decode(String.self, forKey: .category)
        self.equipment = try? c.decode(String.self, forKey: .equipment)
        self.createdAt = try? c.decode(String.self, forKey: .createdAt)

        // bodyweight — React writes `!!ex.bodyweight`, but raw imports can
        // be absent. Fall back to inferring from a "BW" weightLabel.
        if let b = try? c.decode(Bool.self, forKey: .bodyweight) {
            self.bodyweight = b
        } else {
            self.bodyweight = (parsedWeightLabel?.uppercased() == "BW")
        }

        self.readyToProgress = (try? c.decode(Bool.self, forKey: .readyToProgress)) ?? false
        self.isCustom        = try? c.decode(Bool.self, forKey: .isCustom)

        // restTimer — accept Int or numeric String. Nil = use default.
        if let n = try? c.decode(Int.self, forKey: .restTimer) {
            self.restTimer = n
        } else if let d = try? c.decode(Double.self, forKey: .restTimer) {
            self.restTimer = Int(d)
        } else if let s = try? c.decode(String.self, forKey: .restTimer),
                  let n = Int(s.trimmingCharacters(in: .whitespaces)) {
            self.restTimer = n
        } else {
            self.restTimer = nil
        }

        // key — defaults to a slug from name when null / missing / empty.
        if let k = try? c.decode(String.self, forKey: .key), !k.isEmpty {
            self.key = k
        } else {
            self.key = Self.slug(from: self.name)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name,            forKey: .name)
        try c.encode(key,             forKey: .key)
        try c.encode(sets,            forKey: .sets)
        try c.encode(reps,            forKey: .reps)
        if let w = weight        { try c.encode(w,   forKey: .weight) }
        if let l = weightLabel   { try c.encode(l,   forKey: .weightLabel) }
        if let t = tag           { try c.encode(t,   forKey: .tag) }
        if let r = rpe           { try c.encode(r,   forKey: .rpe) }
        if let n = notes         { try c.encode(n,   forKey: .notes) }
        try c.encode(bodyweight,      forKey: .bodyweight)
        if let m = muscle        { try c.encode(m,   forKey: .muscle) }
        try c.encode(readyToProgress, forKey: .readyToProgress)
        if let v = isCustom      { try c.encode(v,   forKey: .isCustom) }
        if let cat = category    { try c.encode(cat, forKey: .category) }
        if let eq = equipment    { try c.encode(eq,  forKey: .equipment) }
        if let cr = createdAt    { try c.encode(cr,  forKey: .createdAt) }
        if let rt = restTimer    { try c.encode(rt,  forKey: .restTimer) }
    }
}

// MARK: - Rest-timer presets

/// Shared rest-timer constants used by ProgrammePage (editing) + TrainView
/// (display + countdown). Mirrors React's `TIMER_PRESETS` from
/// `src/components/shared/RestTimer.jsx` so the same selection set surfaces
/// on iOS and the web.
enum RestTimerPresets {

    /// One pill in the rest-timer row. `seconds == nil` represents the
    /// "Custom" trailing pill that opens a numeric input.
    struct Preset: Hashable, Identifiable {
        let label: String        // English label, e.g. "30s", "1 min"
        let arabicLabel: String  // e.g. "٣٠ ث", "دقيقة"
        let seconds: Int?        // nil → custom (opens input)
        var id: String { label }
        var isCustom: Bool { seconds == nil }
    }

    /// The fixed preset order (Off → 30s → 45s → 1 min → 90s → 2 min → Custom).
    static let all: [Preset] = [
        Preset(label: "Off",    arabicLabel: "إيقاف",  seconds: 0),
        Preset(label: "30s",    arabicLabel: "٣٠ ث",   seconds: 30),
        Preset(label: "45s",    arabicLabel: "٤٥ ث",   seconds: 45),
        Preset(label: "1 min",  arabicLabel: "دقيقة",  seconds: 60),
        Preset(label: "90s",    arabicLabel: "٩٠ ث",   seconds: 90),
        Preset(label: "2 min",  arabicLabel: "دقيقتان", seconds: 120),
        Preset(label: "Custom", arabicLabel: "مخصص",   seconds: nil),
    ]

    /// Default rest seconds for an exercise based on its `tag`/bodyweight,
    /// matching `getDefaultRestDuration` in React's RestTimer.jsx.
    /// Compounds rest 90s; everything else 60s.
    static func defaultSeconds(for ex: Exercise) -> Int {
        let tag = (ex.tag ?? "").lowercased()
        return tag == "compound" ? 90 : 60
    }

    /// Resolve the effective rest seconds for an exercise — the user's
    /// persisted choice if set, otherwise the tag-based default.
    static func effectiveSeconds(for ex: Exercise) -> Int {
        ex.restTimer ?? defaultSeconds(for: ex)
    }

    /// Returns the matching preset for a given seconds value, or `nil`
    /// when the value isn't one of the fixed presets (use "Custom" pill).
    static func preset(for seconds: Int) -> Preset? {
        all.first { $0.seconds == seconds }
    }
}

// MARK: - Session (workout instance)

struct WorkoutSession: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let programmeId: UUID?
    var name: String
    var date: Date
    var weekNumber: Int?
    /// Free-form block label (e.g. "Block 1" / "Week 1-4 — Volume").
    /// React stores this as text — historically I had it as Int? which
    /// caused every row to fail decode.
    var block: String?
    var completed: Bool
    var data: WorkoutSessionData?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId      = "user_id"
        case programmeId = "programme_id"
        case name
        case date
        case weekNumber  = "week_number"
        case block
        case completed
        case data
        case createdAt   = "created_at"
    }

    init(id: UUID, userId: UUID, programmeId: UUID?, name: String,
         date: Date, weekNumber: Int?, block: String?, completed: Bool,
         data: WorkoutSessionData?, createdAt: Date?) {
        self.id = id; self.userId = userId; self.programmeId = programmeId
        self.name = name; self.date = date; self.weekNumber = weekNumber
        self.block = block; self.completed = completed; self.data = data
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id          = try c.decode(UUID.self,   forKey: .id)
        self.userId      = try c.decode(UUID.self,   forKey: .userId)
        self.programmeId = try? c.decode(UUID.self,  forKey: .programmeId)
        self.name        = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.date        = try LenientDate.required(c, .date)
        self.weekNumber  = try? c.decode(Int.self,   forKey: .weekNumber)
        // `block` may be text ("Block 1") or — defensively — an integer.
        // Accept either to survive schema drift.
        if let s = try? c.decode(String.self, forKey: .block) {
            self.block = s
        } else if let i = try? c.decode(Int.self, forKey: .block) {
            self.block = String(i)
        } else {
            self.block = nil
        }
        self.completed   = (try? c.decode(Bool.self, forKey: .completed)) ?? false
        self.data        = try? c.decode(WorkoutSessionData.self, forKey: .data)
        self.createdAt   = LenientDate.optional(c, .createdAt)
    }
}

/// Snapshot of exercises/sets attached to a session (JSONB).
struct WorkoutSessionData: Codable, Hashable {
    var exercises: [Exercise]
    /// Active training time in seconds — the gap-capped sum of intervals
    /// between consecutive set ticks (gaps over 30 min are treated as
    /// "not training" and contribute nothing, so a stray tick outside
    /// the gym can't inflate the number). Optional: rows saved before
    /// this feature existed have no value, and the React app ignores
    /// the extra JSON key.
    var durationSeconds: Int? = nil
}

// MARK: - Set

/// One performed set in the `sets` table.
struct PerformedSet: Codable, Identifiable, Hashable {
    let id: UUID
    let sessionId: UUID
    let userId: UUID
    var exerciseName: String
    var setNumber: Int
    var reps: Int?
    var weight: Double?
    var rpe: Double?
    var completed: Bool
    var failed: Bool
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId    = "session_id"
        case userId       = "user_id"
        case exerciseName = "exercise_name"
        case setNumber    = "set_number"
        case reps
        case weight
        case rpe
        case completed
        case failed
        case createdAt    = "created_at"
    }

    init(id: UUID, sessionId: UUID, userId: UUID, exerciseName: String,
         setNumber: Int, reps: Int?, weight: Double?, rpe: Double?,
         completed: Bool, failed: Bool, createdAt: Date?) {
        self.id = id; self.sessionId = sessionId; self.userId = userId
        self.exerciseName = exerciseName; self.setNumber = setNumber
        self.reps = reps; self.weight = weight; self.rpe = rpe
        self.completed = completed; self.failed = failed
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id           = try c.decode(UUID.self,   forKey: .id)
        self.sessionId    = try c.decode(UUID.self,   forKey: .sessionId)
        self.userId       = try c.decode(UUID.self,   forKey: .userId)
        self.exerciseName = (try? c.decode(String.self, forKey: .exerciseName)) ?? ""
        self.setNumber    = (try? c.decode(Int.self,    forKey: .setNumber)) ?? 0
        self.reps         = try? c.decode(Int.self,    forKey: .reps)
        self.weight       = try? c.decode(Double.self, forKey: .weight)
        self.rpe          = try? c.decode(Double.self, forKey: .rpe)
        self.completed    = (try? c.decode(Bool.self,  forKey: .completed)) ?? false
        self.failed       = (try? c.decode(Bool.self,  forKey: .failed))    ?? false
        self.createdAt    = LenientDate.optional(c, .createdAt)
    }
}

// MARK: - Working weight

struct WorkingWeight: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var exerciseName: String
    var weight: Double
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId       = "user_id"
        case exerciseName = "exercise_name"
        case weight
        case updatedAt    = "updated_at"
    }

    init(id: UUID, userId: UUID, exerciseName: String, weight: Double, updatedAt: Date?) {
        self.id = id; self.userId = userId; self.exerciseName = exerciseName
        self.weight = weight; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id           = try c.decode(UUID.self,   forKey: .id)
        self.userId       = try c.decode(UUID.self,   forKey: .userId)
        self.exerciseName = try c.decode(String.self, forKey: .exerciseName)
        self.weight       = try c.decode(Double.self, forKey: .weight)
        self.updatedAt    = LenientDate.optional(c, .updatedAt)
    }
}

// MARK: - Friendship

struct Friendship: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let friendId: UUID
    var status: String         // "pending" | "accepted" | "blocked"
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId    = "user_id"
        case friendId  = "friend_id"
        case status
        case createdAt = "created_at"
    }

    init(id: UUID, userId: UUID, friendId: UUID, status: String, createdAt: Date?) {
        self.id = id; self.userId = userId; self.friendId = friendId
        self.status = status; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id        = try c.decode(UUID.self,   forKey: .id)
        self.userId    = try c.decode(UUID.self,   forKey: .userId)
        self.friendId  = try c.decode(UUID.self,   forKey: .friendId)
        self.status    = try c.decode(String.self, forKey: .status)
        self.createdAt = LenientDate.optional(c, .createdAt)
    }
}

// MARK: - Trophy

struct Trophy: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var trophyKey: String      // "DAY_ONE" | "CENTURY" | etc.
    var trophyName: String
    var earnedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId      = "user_id"
        case trophyKey   = "trophy_key"
        case trophyName  = "trophy_name"
        case earnedAt    = "earned_at"
    }

    init(id: UUID, userId: UUID, trophyKey: String, trophyName: String, earnedAt: Date?) {
        self.id = id; self.userId = userId; self.trophyKey = trophyKey
        self.trophyName = trophyName; self.earnedAt = earnedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id         = try c.decode(UUID.self,   forKey: .id)
        self.userId     = try c.decode(UUID.self,   forKey: .userId)
        self.trophyKey  = try c.decode(String.self, forKey: .trophyKey)
        self.trophyName = try c.decode(String.self, forKey: .trophyName)
        self.earnedAt   = LenientDate.optional(c, .earnedAt)
    }
}

// MARK: - Activity feed

struct ActivityFeedItem: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var type: String           // "session_completed" | "trophy_earned" | "pr" | ...
    var data: [String: AnyCodable]?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId    = "user_id"
        case type
        case data
        case createdAt = "created_at"
    }

    init(id: UUID, userId: UUID, type: String,
         data: [String: AnyCodable]?, createdAt: Date?) {
        self.id = id; self.userId = userId; self.type = type
        self.data = data; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id        = try c.decode(UUID.self,   forKey: .id)
        self.userId    = try c.decode(UUID.self,   forKey: .userId)
        self.type      = (try? c.decode(String.self, forKey: .type)) ?? ""
        self.data      = try? c.decode([String: AnyCodable].self, forKey: .data)
        self.createdAt = LenientDate.optional(c, .createdAt)
    }
}

// MARK: - AnyCodable (for free-form JSON columns)

/// Type-erased Codable wrapper so we can decode JSONB columns with mixed
/// value types without defining a struct for every shape.
struct AnyCodable: Codable, Hashable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self.value = NSNull()
        } else if let b = try? c.decode(Bool.self) {
            self.value = b
        } else if let i = try? c.decode(Int.self) {
            self.value = i
        } else if let d = try? c.decode(Double.self) {
            self.value = d
        } else if let s = try? c.decode(String.self) {
            self.value = s
        } else if let arr = try? c.decode([AnyCodable].self) {
            self.value = arr.map(\.value)
        } else if let dict = try? c.decode([String: AnyCodable].self) {
            self.value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "AnyCodable: unsupported value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull:                  try c.encodeNil()
        case let b as Bool:              try c.encode(b)
        case let i as Int:               try c.encode(i)
        case let d as Double:            try c.encode(d)
        case let s as String:            try c.encode(s)
        case let arr as [Any]:           try c.encode(arr.map(AnyCodable.init))
        case let dict as [String: Any]:  try c.encode(dict.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(codingPath: c.codingPath,
                                      debugDescription: "AnyCodable: cannot encode \(value)"))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Encode-based equality — good enough for use in Hashable contexts.
        let enc = JSONEncoder()
        return (try? enc.encode(lhs)) == (try? enc.encode(rhs))
    }

    func hash(into hasher: inout Hasher) {
        if let data = try? JSONEncoder().encode(self) {
            hasher.combine(data)
        }
    }
}
