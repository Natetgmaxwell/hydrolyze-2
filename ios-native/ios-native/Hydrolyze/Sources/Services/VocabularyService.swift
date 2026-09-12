import Foundation
import Supabase

/// VocabularyService — the RPE flywheel.
///
/// When the coach writes ambiguous intensity terms ("moderate", "hard", "easy"),
/// the parser flags them. The UI prompts the coach to assign an RPE range.
/// That mapping is saved here. Next time the same coach uses "moderate",
/// it silently resolves to the saved RPE.
///
/// Per coach: each coach has their own vocabulary. One coach's "moderate"
/// is RPE 6-7, another's might be RPE 5-6.
actor VocabularyService {
    static let shared = VocabularyService()

    /// In-memory cache: term → RPE range. Loaded once per session.
    private var cache: [String: RPERange] = [:]
    private var loaded = false

    /// Nonisolated sync lookup for use in SwiftUI view bodies.
    /// Reads from the same cache via a lock — safe to call from main thread.
    private static let cacheLock = NSLock()
    private static var cacheSnapshot: [String: RPERange] = [:]

    /// RPE range bucket. The UI picker offers these 4 buckets:
    /// RPE 4-5 (easy aerobic), 6-7 (moderate-aerobic), 8-9 (threshold-hard), 10 (max sprint)
    struct RPERange: Codable, Sendable, Hashable {
        let low: Int
        let high: Int

        var label: String {
            low == high ? "RPE\(low)" : "RPE\(low)-\(high)"
        }
    }

    /// Predefined RPE buckets for the picker UI.
    static let rpeBuckets: [RPERange] = [
        RPERange(low: 4, high: 5),    // Easy / recovery
        RPERange(low: 6, high: 7),    // Moderate / aerobic
        RPERange(low: 8, high: 9),    // Hard / threshold
        RPERange(low: 10, high: 10),  // Max / sprint
    ]

    /// Load all vocabulary for the current coach into the cache.
    func loadVocabulary() async {
        guard !loaded else { return }
        do {
            let response: [VocabularyEntry] = try await SupabaseService.shared.client
                .from("coach_vocabulary")
                .select()
                .execute()
                .value
            for entry in response {
                cache[entry.userTerm] = RPERange(low: entry.rpeLow, high: entry.rpeHigh)
            }
            loaded = true
            // Sync the nonisolated snapshot so SwiftUI views can read it
            Self.syncSnapshot(cache)
        } catch {
            print("⚠️ VocabularyService.loadVocabulary error: \(error)")
        }
    }

    /// Look up an ambiguous term in the cache.
    /// Returns the RPE range if the coach has mapped this term before, nil otherwise.
    func lookup(_ term: String) -> RPERange? {
        cache[term.lowercased()]
    }

    /// Nonisolated sync lookup — safe to call from SwiftUI view bodies.
    static func lookupSync(_ term: String) -> RPERange? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cacheSnapshot[term.lowercased()]
    }

    private static func syncSnapshot(_ cache: [String: RPERange]) {
        cacheLock.lock()
        cacheSnapshot = cache
        cacheLock.unlock()
    }

    /// Save a mapping. Writes to DB and updates the cache.
    func saveMapping(term: String, rpe: RPERange) async {
        let entry = VocabularyEntry(
            userTerm: term.lowercased(),
            rpeLow: rpe.low,
            rpeHigh: rpe.high
        )

        do {
            _ = try await SupabaseService.shared.client
                .from("coach_vocabulary")
                .upsert(entry)
                .execute()
            cache[term.lowercased()] = rpe
            Self.syncSnapshot(cache)
        } catch {
            print("⚠️ VocabularyService.saveMapping error: \(error)")
        }
    }

    /// Check if a term is ambiguous (needs RPE mapping).
    /// V0.47: aligned with engine `AMBIGUOUS_INTENSITY_TERMS` via the shared
    /// `_dialect-terms.ts` source-of-truth (16 Tier-1 entries; the
    /// PROGRESSION_TERMS set {build, descend, desc} is handled separately
    /// by the 2-point capture in the end-of-session card — not in this set).
    /// KEEP IN SYNC with V0.47_DIALECT.md §3 (locked 2026-08-21, commit e7e394b)
    /// and the three TS mirrors at:
    ///   - scripts/parser-bench/_dialect-terms.ts
    ///   - supabase/functions/parse-workout/_dialect-terms.ts
    ///   - ios-native/supabase/functions/parse-workout/_dialect-terms.ts
    /// When adding/removing a term, update all four locations in the same PR.
    static let ambiguousTerms: Set<String> = [
        "moderate", "hard", "steady", "cruise",
        "light", "tough", "strong", "all-out",
        "relaxed", "progressive", "activation", "maximal",
        "race rhythm", "faster than race pace", "fast", "max",
    ]
}

/// DB row for coach_vocabulary table.
struct VocabularyEntry: Codable {
    let userTerm: String
    let rpeLow: Int
    let rpeHigh: Int
    let sampleCount: Int?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case userTerm = "user_term"
        case rpeLow = "rpe_low"
        case rpeHigh = "rpe_high"
        case sampleCount = "sample_count"
        case updatedAt = "updated_at"
    }

    init(userTerm: String, rpeLow: Int, rpeHigh: Int, sampleCount: Int? = nil, updatedAt: String? = nil) {
        self.userTerm = userTerm
        self.rpeLow = rpeLow
        self.rpeHigh = rpeHigh
        self.sampleCount = sampleCount
        self.updatedAt = updatedAt
    }
}
