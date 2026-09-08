import Foundation

/// ConsoleState — the four states of `SessionConsoleView`. Owns the
/// single-source-of-truth for which screen the coach sees. Per V0.54
/// spec §"States and transitions":
///
///   PRE    → breadcrumb + Start Session CTA (only CTA)
///   LIVE   → current rep's stopwatch + completed-rep one-liners
///   BETWEEN→ send-off countdown + Next-rep pill (sub-state of LIVE)
///   POST   → one row per rep + Review pairs + End session
///
/// Decision 12: BETWEEN is a sibling of LIVE (different timer kind,
/// different cadence). Decision 2: each state is a single screen with
/// one primary CTA. Transitions are owned by `SessionConsoleViewModel`
/// (state advances are method calls, not SwiftUI bindings).
enum ConsoleState: Equatable {
    case pre
    case live
    case between
    case post
}