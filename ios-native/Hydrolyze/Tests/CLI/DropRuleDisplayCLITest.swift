// DropRuleDisplayCLITest — V0.39 Slice 3 — pure-helper CLI test for
// the interval-to-seconds parser and the inline-badge display
// formatters. These helpers live in `RestCountdownModel.swift` (the
// same file as the model) so the orchestrator-Mac CLI runner can
// compile them without UIKit. The VM-side wiring (driving
// `model.tick()` from the 10ms timer, calling `evaluate(...)` on
// each LAP, and rendering the badge) is UIKit-bound and can't be
// CLI-tested in this stance — the pure helpers carry the test burden
// for the slice-3 acceptance surface.
//
// What it covers (spec §Slice 3 TDD):
//   1. intervalToSeconds: "m:ss" canonical, bare seconds, malformed
//   2. formatRepDelta: positive, zero, negative deltas
//   3. formatRepTime: 1dp, exact-integer reps
//   4. formatRestSec: minutes, sub-minute, zero clamp
//
// Usage: DropRuleDisplayCLITest
// Compiled by build_and_run_dropruledisplay.sh.

import Foundation

// MARK: - Helpers

func drPass(_ label: String, _ ok: Bool, extra: String = "") {
    let mark = ok ? "PASS" : "FAIL"
    let suffix = extra.isEmpty ? "" : " — \(extra)"
    print("  [\(mark)] \(label)\(suffix)")
}

func drEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) -> Bool {
    let ok = actual == expected
    drPass(label, ok, extra: "actual=\(actual) expected=\(expected)")
    return ok
}

func drNil<T>(_ label: String, _ actual: T?) -> Bool {
    let ok = actual == nil
    drPass(label, ok, extra: "actual=\(String(describing: actual))")
    return ok
}

// MARK: - Test 1: intervalToSeconds

func runIntervalToSeconds() -> Bool {
    print("\n=== TEST 1: intervalToSeconds ===")
    var allPass = true
    allPass = drEq("\"4:30\" → 270", intervalToSeconds("4:30"), 270) && allPass
    allPass = drEq("\"1:00\" → 60", intervalToSeconds("1:00"), 60) && allPass
    allPass = drEq("\"45\" → 45 (bare seconds)", intervalToSeconds("45"), 45) && allPass
    allPass = drEq("\"1:30\" → 90", intervalToSeconds("1:30"), 90) && allPass
    allPass = drEq("\"0:05\" → 5", intervalToSeconds("0:05"), 5) && allPass
    allPass = drEq("\"3:00\" → 180", intervalToSeconds("3:00"), 180) && allPass
    allPass = drNil("malformed \"abc\" → nil", intervalToSeconds("abc")) && allPass
    allPass = drNil("malformed \"1:\" → nil", intervalToSeconds("1:")) && allPass
    allPass = drNil("malformed \"\" → nil", intervalToSeconds("")) && allPass
    allPass = drEq("\" 1:30 \" → 90 (whitespace trimmed, then parsed)", intervalToSeconds(" 1:30 "), 90) && allPass
    allPass = drNil("nil → nil", intervalToSeconds(nil)) && allPass

    print("  -> TEST 1: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 2: formatRepDelta

func runFormatRepDelta() -> Bool {
    print("\n=== TEST 2: formatRepDelta ===")
    var allPass = true
    allPass = drEq("27800 vs 27000 → \"+0.8\"", formatRepDelta(repTimeMs: 27800, standardMs: 27000), "+0.8") && allPass
    allPass = drEq("27000 vs 27000 → \"+0.0\"", formatRepDelta(repTimeMs: 27000, standardMs: 27000), "+0.0") && allPass
    allPass = drEq("26600 vs 27000 → \"-0.4\"", formatRepDelta(repTimeMs: 26600, standardMs: 27000), "-0.4") && allPass
    allPass = drEq("27050 vs 27000 → \"+0.1\" (50ms)", formatRepDelta(repTimeMs: 27050, standardMs: 27000), "+0.1") && allPass
    allPass = drEq("spec example - 60700 vs 60000 → \"+0.7\"", formatRepDelta(repTimeMs: 60700, standardMs: 60000), "+0.7") && allPass

    print("  -> TEST 2: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 3: formatRepTime

func runFormatRepTime() -> Bool {
    print("\n=== TEST 3: formatRepTime ===")
    var allPass = true
    allPass = drEq("27800 → \"27.8\"", formatRepTime(27800), "27.8") && allPass
    allPass = drEq("27000 → \"27.0\" (exact integer, 1dp)", formatRepTime(27000), "27.0") && allPass
    allPass = drEq("32100 → \"32.1\"", formatRepTime(32100), "32.1") && allPass
    allPass = drEq("0 → \"0.0\"", formatRepTime(0), "0.0") && allPass
    allPass = drEq("60900 → \"60.9\"", formatRepTime(60900), "60.9") && allPass

    print("  -> TEST 3: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Test 4: formatRestSec

func runFormatRestSec() -> Bool {
    print("\n=== TEST 4: formatRestSec ===")
    var allPass = true
    allPass = drEq("300 → \"5:00\"", formatRestSec(300), "5:00") && allPass
    allPass = drEq("60 → \"1:00\"", formatRestSec(60), "1:00") && allPass
    allPass = drEq("30 → \"0:30\"", formatRestSec(30), "0:30") && allPass
    allPass = drEq("0 → \"0:00\"", formatRestSec(0), "0:00") && allPass
    allPass = drEq("360 → \"6:00\"", formatRestSec(360), "6:00") && allPass
    allPass = drEq("5 → \"0:05\" (sub-second zero-pad)", formatRestSec(5), "0:05") && allPass
    allPass = drEq("negative -10 → \"0:00\" (clamp)", formatRestSec(-10), "0:00") && allPass
    allPass = drEq("270 → \"4:30\" (the canonical interval)", formatRestSec(270), "4:30") && allPass

    print("  -> TEST 4: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Main

@main
struct DropRuleDisplayCLITest {
    static func main() {
        print("=== DropRuleDisplayCLI Test — V0.39 Slice 3 ===")
        print("=== Pure-helper gate for the inline-badge surface. ===")
        print("=== intervalToSeconds + formatRepDelta + formatRepTime + formatRestSec. ===")
        print("")

        let t1 = runIntervalToSeconds()
        let t2 = runFormatRepDelta()
        let t3 = runFormatRepTime()
        let t4 = runFormatRestSec()

        let results: [(String, Bool)] = [
            ("TEST 1 intervalToSeconds", t1),
            ("TEST 2 formatRepDelta",    t2),
            ("TEST 3 formatRepTime",     t3),
            ("TEST 4 formatRestSec",     t4),
        ]

        print("\n=== Summary ===")
        var allPass = true
        for (name, passed) in results {
            let mark = passed ? "PASS" : "FAIL"
            print("  [\(mark)] \(name)")
            if !passed { allPass = false }
        }
        print("")
        print("=== Overall: \(allPass ? "ALL PASS ✓" : "FAILURES ✗") ===")

        if !allPass {
            exit(1)
        }
    }
}
