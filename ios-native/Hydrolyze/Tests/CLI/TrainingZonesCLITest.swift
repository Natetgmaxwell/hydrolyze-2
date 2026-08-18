// TrainingZonesCLITest — V0.40 Slice 1 — pure-logic CLI test of the
// new TrainingZoneService. Exercises the boundary math (Easy/Steady/
// Hard/Sprint as constants of critical speed), the per-100m pace
// rendering (via thresholdPaceString reuse), the peak clamp (sprint
// never inverts below hard), and the defensive nil-on-invalid-CS
// contract — so the zone math can be regression-gated on the
// orchestrator Mac without a booted simulator or a Supabase client.
//
// What it covers (V0.40_SPEC.md §Slice 1 acceptance):
//   1. Boundary math: 1.33 m/s CS → easy=1.184, steady=1.33,
//      hard=1.377 m/s (constants 0.89 / 1.0 / 1.035 × CS).
//   2. Pace strings: render as mm:ss/100m via
//      thresholdPaceString (e.g. 1.33 m/s → "1:15/100m"); no banned
//      jargon in any zone string.
//   3. peak ≥ 1.035×CS reaches Sprint: sprint boundary is the
//      observed peak (the top of the Sprint zone).
//   4. peak < 1.035×CS clamps sprint to the boundary: the peak
//      being below the hard/sprint line is data, not a reason to
//      invert the pace order — sprint.mps ≥ hard.mps always.
//   5. Invalid CS returns nil (defensive — 0, negative, nan, +∞).
//   6. Invalid peak falls back to the boundary: 0, negative, nan,
//      +∞ peak → sprint = 1.035×CS (no infinity leak into the
//      pace string).
//   7. sourceTrialNumber round-trips through derive() unchanged.
//
// Coach vocabulary pinned by these tests: Easy / Steady / Hard /
// Sprint. No "zone 1–4", no "LT", no "vVO₂max", no "critical
// speed" in any zone name string. The struct properties are
// `easy`/`steady`/`hard`/`sprint` per the spec; the test exercises
// those property names by construction.
//
// Usage: TrainingZonesCLITest
// Compiled by build_and_run_trainingzones.sh.

import Foundation

// MARK: - Helpers

func assertEq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) -> Bool {
    let ok = actual == expected
    let mark = ok ? "PASS" : "FAIL"
    print("  [\(mark)] \(label): actual=\(actual) expected=\(expected)")
    return ok
}

func assertTrue(_ label: String, _ condition: Bool, extra: String = "") -> Bool {
    let mark = condition ? "PASS" : "FAIL"
    let suffix = extra.isEmpty ? "" : " (\(extra))"
    print("  [\(mark)] \(label)\(suffix)")
    return condition
}

/// Boundary math involves m/s values that arise from
/// multiplication of a critical speed by a constant — IEEE 754
/// roundoff can shift the last decimal. Use a sub-1cm/s tolerance
/// (0.0005 m/s) which is well below the spec's 3-decimal display
/// (e.g. 1.1837 → 1.184, off by 0.0003) and well above the
/// floating-point noise floor.
func assertApprox(
    _ label: String,
    _ actual: Double,
    _ expected: Double,
    tolerance: Double = 0.0005
) -> Bool {
    let ok = abs(actual - expected) <= tolerance
    let mark = ok ? "PASS" : "FAIL"
    print("  [\(mark)] \(label): actual=\(actual) expected=\(expected)±\(tolerance)")
    return ok
}

// MARK: - TEST 1 — boundary math (1.33 CS)

/// Verifies the four boundary speeds at 1.33 m/s critical speed.
/// The constants are 0.89 (Easy/Steady), 1.0 (Steady/Hard), 1.035
/// (Hard/Sprint) × CS. The peak is set well above 1.035×CS so the
/// sprint boundary is the peak (covered in TEST 3); here we
/// exercise only Easy/Steady/Hard against the constant multipliers.
func runBoundaryMath() -> Bool {
    print("\n=== TEST 1: boundary math (1.33 CS) ===")

    let cs = 1.33
    guard let zones = TrainingZoneService.derive(
        criticalSpeedMps: cs,
        peakSpeedMps: 1.50,
        sourceTrialNumber: 3
    ) else {
        print("  [FAIL] derive(1.33, 1.50, 3) returned nil for a valid CS")
        return false
    }

    var allPass = true

    // Easy boundary: 0.89 × 1.33 = 1.1837 (spec says 1.184 rounded).
    allPass = assertApprox(
        "easy boundary = 0.89 × CS (≈ 1.184)",
        zones.easy.mps, 0.89 * cs
    ) && allPass
    allPass = assertApprox(
        "easy boundary ≈ 1.184 m/s (spec rounded)",
        zones.easy.mps, 1.184
    ) && allPass

    // Steady boundary: 1.0 × 1.33 = 1.33 exactly.
    allPass = assertEq(
        "steady boundary = 1.0 × CS (= 1.33)",
        zones.steady.mps, cs
    ) && allPass

    // Hard boundary: 1.035 × 1.33 = 1.37655 (spec says 1.377 rounded).
    allPass = assertApprox(
        "hard boundary = 1.035 × CS (≈ 1.37655)",
        zones.hard.mps, 1.035 * cs
    ) && allPass
    allPass = assertApprox(
        "hard boundary ≈ 1.377 m/s (spec rounded)",
        zones.hard.mps, 1.377
    ) && allPass

    // criticalSpeedMps round-trips unchanged.
    allPass = assertEq(
        "criticalSpeedMps round-trips",
        zones.criticalSpeedMps, cs
    ) && allPass

    print("  -> TEST 1: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 2 — pace strings (mm:ss/100m)

/// Verifies the pace string for each zone renders as "m:ss/100m"
/// via the existing `thresholdPaceString` from
/// ThreeMTReviewSupport. Worked example: 1.33 m/s → 100/1.33 =
/// 75.19s → 75s = "1:15/100m". The "/100m" suffix is mandatory so
/// the coach reads the unit against the chart.
func runPaceStrings() -> Bool {
    print("\n=== TEST 2: pace strings (mm:ss/100m) ===")

    let cs = 1.33
    guard let zones = TrainingZoneService.derive(
        criticalSpeedMps: cs,
        peakSpeedMps: 1.50,
        sourceTrialNumber: 3
    ) else {
        print("  [FAIL] derive(1.33, 1.50, 3) returned nil for a valid CS")
        return false
    }

    var allPass = true

    // Steady = CS = 1.33 m/s → 75s = 1:15/100m (spec worked example).
    allPass = assertEq(
        "steady pace = \"1:15/100m\" (1.33 m/s → 75.19s → 75s)",
        zones.steady.paceString ?? "nil",
        "1:15/100m"
    ) && allPass

    // Easy = 1.184 m/s → 100/1.184 = 84.46s → 84s = 1:24/100m.
    allPass = assertEq(
        "easy pace = \"1:24/100m\" (1.184 m/s → 84.46s → 84s)",
        zones.easy.paceString ?? "nil",
        "1:24/100m"
    ) && allPass

    // Hard = 1.377 m/s → 100/1.377 = 72.62s → 73s = 1:13/100m.
    allPass = assertEq(
        "hard pace = \"1:13/100m\" (1.377 m/s → 72.62s → 73s)",
        zones.hard.paceString ?? "nil",
        "1:13/100m"
    ) && allPass

    // Sprint = peak = 1.50 m/s → 100/1.50 = 66.67s → 67s = 1:07/100m.
    allPass = assertEq(
        "sprint pace = \"1:07/100m\" (1.50 m/s → 66.67s → 67s)",
        zones.sprint.paceString ?? "nil",
        "1:07/100m"
    ) && allPass

    // Every zone's pace string must contain "/100m" — the unit
    // suffix is part of the coach-facing contract (m:ss alone
    // would be ambiguous against the 25m split pace).
    for (name, pace) in [
        ("easy", zones.easy.paceString ?? ""),
        ("steady", zones.steady.paceString ?? ""),
        ("hard", zones.hard.paceString ?? ""),
        ("sprint", zones.sprint.paceString ?? "")
    ] {
        allPass = assertTrue(
            "\(name) pace string contains \"/100m\" unit suffix",
            pace.contains("/100m"),
            extra: "pace=\"\(pace)\""
        ) && allPass
    }

    // No pace string contains banned jargon. The work order pins
    // Easy/Steady/Hard/Sprint vocabulary; no LT / vVO₂max / CS /
    // "zone 1-4" / "critical" should leak into a user-facing pace.
    let banned = [
        "zone 1", "zone 2", "zone 3", "zone 4",
        "LT", "vVO", "critical", "anaerobic", "D'"
    ]
    for (name, pace) in [
        ("easy", zones.easy.paceString ?? ""),
        ("steady", zones.steady.paceString ?? ""),
        ("hard", zones.hard.paceString ?? ""),
        ("sprint", zones.sprint.paceString ?? "")
    ] {
        for word in banned {
            allPass = assertTrue(
                "\(name) pace string omits banned term \"\(word)\"",
                !pace.contains(word),
                extra: "pace=\"\(pace)\""
            ) && allPass
        }
    }

    print("  -> TEST 2: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 3 — peak >= 1.035×CS reaches Sprint

/// When the swimmer's observed peak is at or above 1.035×CS, the
/// peak is the top of the Sprint zone — they reach it. The slice
/// spec (line 50) pins this: "peak speed ≥ 1.035×CS means the
/// swimmer reaches Sprint".
func runPeakReachesSprint() -> Bool {
    print("\n=== TEST 3: peak >= 1.035×CS reaches Sprint ===")

    let cs = 1.33
    let hardBoundary = 1.035 * cs  // ≈ 1.37655

    var allPass = true

    // Peak clearly above 1.035×CS → sprint = peak.
    if let z1 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: 1.40, sourceTrialNumber: 3
    ) {
        allPass = assertEq(
            "peak 1.40 (>> 1.035×CS) → sprint = peak",
            z1.sprint.mps, 1.40
        ) && allPass
        allPass = assertTrue(
            "sprint strictly > hard when peak > 1.035×CS",
            z1.sprint.mps > z1.hard.mps,
            extra: "sprint=\(z1.sprint.mps) hard=\(z1.hard.mps)"
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, 1.40, 3) returned nil")
        allPass = false
    }

    // Peak well above (sprinter signature) → sprint = peak.
    if let z2 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: 1.65, sourceTrialNumber: 3
    ) {
        allPass = assertEq(
            "peak 1.65 → sprint = peak",
            z2.sprint.mps, 1.65
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, 1.65, 3) returned nil")
        allPass = false
    }

    // Peak exactly at 1.035×CS → sprint = peak = boundary (still
    // "reaches Sprint" — the top of the zone equals the floor).
    let peakAtBoundary = hardBoundary
    if let z3 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: peakAtBoundary, sourceTrialNumber: 3
    ) {
        allPass = assertApprox(
            "peak = 1.035×CS → sprint = boundary (top of sprint = floor)",
            z3.sprint.mps, hardBoundary
        ) && allPass
        allPass = assertApprox(
            "sprint = hard when peak = boundary",
            z3.sprint.mps, z3.hard.mps
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, hard, 3) returned nil")
        allPass = false
    }

    print("  -> TEST 3: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 4 — peak below 1.035×CS clamps sprint (no inversion)

/// When the observed peak is below the hard/sprint boundary, the
/// swimmer has not demonstrated a Sprint — peak is data, not a
/// reason to invert the pace order. Sprint.mps is clamped to the
/// boundary (max(peak, 1.035×CS)), so the sprint pace string is
/// never slower than the hard pace string. The slice spec (line
/// 45) is explicit: "peak is clamped to be >= the sprint boundary
/// when the observed peak is below 1.035×CS (so sprint pace never
/// inverts below hard)".
func runPeakClampsSprint() -> Bool {
    print("\n=== TEST 4: peak below 1.035×CS clamps sprint (no inversion) ===")

    let cs = 1.33
    let hardBoundary = 1.035 * cs  // ≈ 1.37655

    var allPass = true

    // Peak 1.35 (below 1.37655) → sprint clamped to the boundary,
    // not the raw peak. The boundary is what the coach sees, and
    // the peak itself stays surfaced via the upstream
    // ThreeMinuteTestAnalyzer result (this service only emits
    // zone boundaries).
    if let z1 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: 1.35, sourceTrialNumber: 3
    ) {
        allPass = assertApprox(
            "peak 1.35 (< 1.035×CS) → sprint clamped to 1.035×CS",
            z1.sprint.mps, hardBoundary
        ) && allPass
        allPass = assertTrue(
            "sprint never inverts below hard (sprint ≥ hard)",
            z1.sprint.mps >= z1.hard.mps,
            extra: "sprint=\(z1.sprint.mps) hard=\(z1.hard.mps)"
        ) && allPass
        allPass = assertEq(
            "sprint.mps ≠ peak when peak < 1.035×CS (boundary wins)",
            z1.sprint.mps == 1.35,
            false
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, 1.35, 3) returned nil")
        allPass = false
    }

    // Peak 1.00 (way below — paced trial signature) → still clamped.
    if let z2 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: 1.00, sourceTrialNumber: 3
    ) {
        allPass = assertApprox(
            "peak 1.00 (way below) → sprint clamped to 1.035×CS",
            z2.sprint.mps, hardBoundary
        ) && allPass
        allPass = assertTrue(
            "sprint ≥ hard even when peak is far below",
            z2.sprint.mps >= z2.hard.mps
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, 1.00, 3) returned nil")
        allPass = false
    }

    // Peak 0.1 (essentially at CS — learning-trial signature) →
    // still clamped to the hard boundary.
    if let z3 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: 0.1, sourceTrialNumber: 1
    ) {
        allPass = assertApprox(
            "peak 0.1 (learning-trial signature) → sprint clamped",
            z3.sprint.mps, hardBoundary
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, 0.1, 1) returned nil")
        allPass = false
    }

    // Pace string consistency: when peak < 1.035×CS, the sprint
    // pace string equals the hard pace string (same boundary m/s,
    // same rounded per-100m). Coach reads identical numbers and
    // knows there's no Sprint data above it.
    if let z4 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: 1.20, sourceTrialNumber: 2
    ) {
        allPass = assertEq(
            "sprint pace string = hard pace string when peak < 1.035×CS",
            z4.sprint.paceString, z4.hard.paceString
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, 1.20, 2) returned nil")
        allPass = false
    }

    print("  -> TEST 4: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 5 — invalid CS returns nil (defensive)

/// The spec's "Never crashes on edge input" acceptance: 0, negative,
/// NaN, +∞ critical speed all return nil. No boundary math, no
/// pace string, no exception.
func runInvalidCSReturnsNil() -> Bool {
    print("\n=== TEST 5: invalid CS returns nil (defensive) ===")

    var allPass = true

    allPass = assertTrue(
        "CS = 0 → nil",
        TrainingZoneService.derive(
            criticalSpeedMps: 0.0, peakSpeedMps: 1.5, sourceTrialNumber: 3
        ) == nil
    ) && allPass

    allPass = assertTrue(
        "CS = -1.0 → nil",
        TrainingZoneService.derive(
            criticalSpeedMps: -1.0, peakSpeedMps: 1.5, sourceTrialNumber: 3
        ) == nil
    ) && allPass

    allPass = assertTrue(
        "CS = -0.5 → nil",
        TrainingZoneService.derive(
            criticalSpeedMps: -0.5, peakSpeedMps: 1.5, sourceTrialNumber: 3
        ) == nil
    ) && allPass

    allPass = assertTrue(
        "CS = NaN → nil",
        TrainingZoneService.derive(
            criticalSpeedMps: .nan, peakSpeedMps: 1.5, sourceTrialNumber: 3
        ) == nil
    ) && allPass

    allPass = assertTrue(
        "CS = +infinity → nil",
        TrainingZoneService.derive(
            criticalSpeedMps: .infinity, peakSpeedMps: 1.5, sourceTrialNumber: 3
        ) == nil
    ) && allPass

    allPass = assertTrue(
        "CS = -infinity → nil",
        TrainingZoneService.derive(
            criticalSpeedMps: -.infinity, peakSpeedMps: 1.5, sourceTrialNumber: 3
        ) == nil
    ) && allPass

    print("  -> TEST 5: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 6 — invalid peak falls back to boundary

/// Peak can be supplied as 0 / negative / NaN / +∞ by upstream
/// callers (e.g. a future UI path that hand-builds the input
/// before the 3MT analyzer runs). The service must not propagate
/// invalid peak into the pace string (0:00/100m from infinity
/// would be visible) — instead, treat peak as "no data" and use
/// the 1.035×CS boundary as the sprint boundary.
func runInvalidPeakFallback() -> Bool {
    print("\n=== TEST 6: invalid peak falls back to boundary ===")

    let cs = 1.33
    let hardBoundary = 1.035 * cs  // ≈ 1.37655

    var allPass = true

    // Peak = 0 → sprint = boundary.
    if let z1 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: 0.0, sourceTrialNumber: 3
    ) {
        allPass = assertApprox(
            "peak = 0 → sprint = 1.035×CS",
            z1.sprint.mps, hardBoundary
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, 0, 3) returned nil (CS valid)")
        allPass = false
    }

    // Peak = -1.0 → sprint = boundary.
    if let z2 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: -1.0, sourceTrialNumber: 3
    ) {
        allPass = assertApprox(
            "peak = -1.0 → sprint = 1.035×CS",
            z2.sprint.mps, hardBoundary
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, -1.0, 3) returned nil")
        allPass = false
    }

    // Peak = NaN → sprint = boundary.
    if let z3 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: .nan, sourceTrialNumber: 3
    ) {
        allPass = assertApprox(
            "peak = NaN → sprint = 1.035×CS",
            z3.sprint.mps, hardBoundary
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, NaN, 3) returned nil")
        allPass = false
    }

    // Peak = +infinity → sprint = boundary (NOT infinity — the
    // service must not let an infinite peak produce a 0:00/100m
    // pace string the coach would see).
    if let z4 = TrainingZoneService.derive(
        criticalSpeedMps: cs, peakSpeedMps: .infinity, sourceTrialNumber: 3
    ) {
        allPass = assertApprox(
            "peak = +infinity → sprint = 1.035×CS (no infinity leak)",
            z4.sprint.mps, hardBoundary
        ) && allPass
        allPass = assertTrue(
            "sprint pace string is well-formed (not 0:00 from infinity)",
            (z4.sprint.paceString ?? "").contains("/100m"),
            extra: "pace=\"\(z4.sprint.paceString ?? "nil")\""
        ) && allPass
    } else {
        print("  [FAIL] derive(1.33, +inf, 3) returned nil")
        allPass = false
    }

    print("  -> TEST 6: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 7 — sourceTrialNumber round-trips

/// The slice struct carries `sourceTrialNumber` so the coach can
/// see which trial the zones were derived from (trials 1–2 are
/// familiarisation per Piatrikova 2019; the resolver in Slice 2
/// will gate the display). For now, the service just passes the
/// number through unchanged.
func runTrialNumberRoundTrip() -> Bool {
    print("\n=== TEST 7: sourceTrialNumber round-trips ===")

    let cs = 1.33
    var allPass = true

    for trial in [1, 2, 3, 4, 7] {
        if let z = TrainingZoneService.derive(
            criticalSpeedMps: cs, peakSpeedMps: 1.50, sourceTrialNumber: trial
        ) {
            allPass = assertEq(
                "trial \(trial) round-trips through sourceTrialNumber",
                z.sourceTrialNumber, trial
            ) && allPass
        } else {
            print("  [FAIL] derive(1.33, 1.50, \(trial)) returned nil")
            allPass = false
        }
    }

    print("  -> TEST 7: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - TEST 8 — usable-profile resolver (V0.40 Slice 2)

// Slice 2 of V0.40 — the "is this profile usable?" gate. A usable
// profile is the latest per (swimmer, stroke) with `trial_number >=
// 2` and NO `learning_trial` quality flag. Trials 1–2 are flagged
// learning per Piatrikova 2019; zones from a learning trial are
// hidden with the "repeat before using" coach line, and the
// downstream display (Slice 3) + drop-rule gate (Slice 4) both
// rely on this resolver to pick the right profile.

/// Build a `SwimmerTestProfile` with explicit control over the
/// fields the resolver cares about (trial number, flags, swimmer
/// id, stroke, test date). All other fields use placeholder
/// values — the resolver only reads `swimmerId`, `stroke`,
/// `trialNumber`, `qualityFlags`, `testDate`. Mirrors the
/// ThreeMTCopyCLITest `makeProfile` shape, extended so the
/// resolver tests can vary each input axis independently.
func makeUsableProfile(
    swimmerId: String = "swimmer-A",
    stroke: String = "Free",
    trialNumber: Int,
    flags: [String] = [],
    testDate: String = "2026-08-15T10:00:00Z"
) -> SwimmerTestProfile {
    return SwimmerTestProfile(
        id: UUID().uuidString,
        swimmerId: swimmerId,
        sessionId: nil,
        workoutSetId: nil,
        stroke: stroke,
        poolLength: 25,
        testDate: testDate,
        trialNumber: trialNumber,
        peakSpeedMps: 1.9,
        criticalSpeedMps: 1.3,
        batteryMeters: 25.0,
        qualityFlags: flags
    )
}

/// Trial-1 only → nil. Per spec §Slice 2 acceptance: a swimmer
/// with only trial 1 has no usable profile; zones are hidden
/// until trial 2 runs and is clean.
func runResolverTrial1Only() -> Bool {
    print("\n=== TEST 8a: resolver — trial-1 only → nil ===")

    var allPass = true
    let profiles = [
        makeUsableProfile(trialNumber: 1)
    ]

    allPass = assertTrue(
        "trial-1 only → nil",
        TrainingZoneService.latestUsableProfile(profiles: profiles) == nil
    ) && allPass

    print("  -> TEST 8a: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// Trial-1 (clean) + trial-2 (clean) → returns the trial-2
/// profile. Per spec §Slice 2 acceptance: returns the trial-2
/// profile when it exists.
func runResolverTrial2Clean() -> Bool {
    print("\n=== TEST 8b: resolver — trial-1 + trial-2 (both clean) → trial-2 ===")

    var allPass = true
    let t1 = makeUsableProfile(trialNumber: 1)
    let t2 = makeUsableProfile(trialNumber: 2)
    let profiles = [t1, t2]

    let resolved = TrainingZoneService.latestUsableProfile(profiles: profiles)
    allPass = assertTrue(
        "trial-1 + trial-2 (both clean) → non-nil",
        resolved != nil
    ) && allPass
    allPass = assertTrue(
        "trial-1 + trial-2 (both clean) → returns trial-2",
        resolved?.id == t2.id
    ) && allPass
    allPass = assertEq(
        "trial-1 + trial-2 (both clean) → trialNumber = 2",
        resolved?.trialNumber, 2
    ) && allPass

    print("  -> TEST 8b: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// Trial-2 (clean) + trial-3 (clean) → returns trial-3. Per
/// spec §Slice 2 acceptance: prefers the newest usable trial
/// (trial 3 beats trial 2 when both usable).
func runResolverNewestWins() -> Bool {
    print("\n=== TEST 8c: resolver — trial-2 + trial-3 (both clean) → trial-3 (newest wins) ===")

    var allPass = true
    let t2 = makeUsableProfile(trialNumber: 2)
    let t3 = makeUsableProfile(trialNumber: 3)
    let profiles = [t2, t3]

    let resolved = TrainingZoneService.latestUsableProfile(profiles: profiles)
    allPass = assertTrue(
        "trial-2 + trial-3 (both clean) → non-nil",
        resolved != nil
    ) && allPass
    allPass = assertTrue(
        "trial-2 + trial-3 (both clean) → returns trial-3 (newest wins)",
        resolved?.id == t3.id
    ) && allPass
    allPass = assertEq(
        "trial-2 + trial-3 (both clean) → trialNumber = 3",
        resolved?.trialNumber, 3
    ) && allPass

    print("  -> TEST 8c: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// Trial-1 (clean) + trial-2 (learning_trial flag) → nil.
/// Learning trials are NOT usable per the spec ("learning
/// trial is NOT usable"). Trial 2 alone with a learning flag
/// means the swimmer has not yet completed the familiarisation
/// trials — no usable profile yet.
func runResolverLearningFlag() -> Bool {
    print("\n=== TEST 8d: resolver — trial-1 + trial-2 (learning flag) → nil ===")

    var allPass = true
    let profiles = [
        makeUsableProfile(trialNumber: 1),
        makeUsableProfile(trialNumber: 2, flags: ["learning_trial"])
    ]

    allPass = assertTrue(
        "trial-1 + trial-2 (learning) → nil (learning not usable)",
        TrainingZoneService.latestUsableProfile(profiles: profiles) == nil
    ) && allPass

    print("  -> TEST 8d: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// Trial-2 (learning) + trial-3 (clean) → returns trial-3.
/// The learning trial is filtered out; the cleanest usable
/// profile wins (trial 3 here).
func runResolverLearningBypassedByClean() -> Bool {
    print("\n=== TEST 8e: resolver — trial-2 (learning) + trial-3 (clean) → trial-3 ===")

    var allPass = true
    let t2 = makeUsableProfile(trialNumber: 2, flags: ["learning_trial"])
    let t3 = makeUsableProfile(trialNumber: 3)
    let profiles = [t2, t3]

    let resolved = TrainingZoneService.latestUsableProfile(profiles: profiles)
    allPass = assertTrue(
        "trial-2 (learning) + trial-3 (clean) → non-nil",
        resolved != nil
    ) && allPass
    allPass = assertTrue(
        "trial-2 (learning) + trial-3 (clean) → returns trial-3 (learning bypassed)",
        resolved?.id == t3.id
    ) && allPass
    allPass = assertEq(
        "trial-2 (learning) + trial-3 (clean) → trialNumber = 3",
        resolved?.trialNumber, 3
    ) && allPass

    print("  -> TEST 8e: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// Empty array → nil. Defensive contract: the resolver never
/// crashes on an empty input (the spec's "Never crashes" rule).
func runResolverEmpty() -> Bool {
    print("\n=== TEST 8f: resolver — empty array → nil ===")

    var allPass = true
    allPass = assertTrue(
        "empty array → nil",
        TrainingZoneService.latestUsableProfile(profiles: []) == nil
    ) && allPass

    print("  -> TEST 8f: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

/// Tie on trial number → broken by the most recent testDate.
/// Per spec §Slice 2: "If multiple profiles share the same max
/// trialNumber (rare — should not happen in practice), return
/// the one with the most recent testDate (ISO8601 string;
/// compare lexicographically — ISO8601 strings sort correctly
/// chronologically)."
func runResolverTestDateTieBreak() -> Bool {
    print("\n=== TEST 8g: resolver — same trialNumber, later testDate wins ===")

    var allPass = true
    let earlyT3 = makeUsableProfile(
        trialNumber: 3,
        testDate: "2026-08-10T10:00:00Z"
    )
    let lateT3 = makeUsableProfile(
        trialNumber: 3,
        testDate: "2026-08-15T10:00:00Z"
    )
    // Order doesn't matter — the resolver picks the most recent.
    let profiles = [earlyT3, lateT3]

    let resolved = TrainingZoneService.latestUsableProfile(profiles: profiles)
    allPass = assertTrue(
        "same trialNumber, two testDates → non-nil",
        resolved != nil
    ) && allPass
    allPass = assertTrue(
        "same trialNumber → later testDate wins (lexicographic = chronological)",
        resolved?.id == lateT3.id
    ) && allPass

    print("  -> TEST 8g: \(allPass ? "PASS" : "FAIL")")
    return allPass
}

// MARK: - Main

@main
struct TrainingZonesCLITest {
    static func main() {
        print("=== TrainingZonesCLI Test — V0.40 Slices 1 + 2 ===")
        print("=== Pure-logic gate for TrainingZoneService ===")
        print("=== Easy/Steady/Hard/Sprint from 3MT critical speed ===")
        print("=== Boundary math, pace rendering, peak clamp, nil-on-bad-CS ===")
        print("=== Usable-profile resolver (Slice 2): latest usable trial ===")
        print("")

        let t1 = runBoundaryMath()
        let t2 = runPaceStrings()
        let t3 = runPeakReachesSprint()
        let t4 = runPeakClampsSprint()
        let t5 = runInvalidCSReturnsNil()
        let t6 = runInvalidPeakFallback()
        let t7 = runTrialNumberRoundTrip()

        let t8a = runResolverTrial1Only()
        let t8b = runResolverTrial2Clean()
        let t8c = runResolverNewestWins()
        let t8d = runResolverLearningFlag()
        let t8e = runResolverLearningBypassedByClean()
        let t8f = runResolverEmpty()
        let t8g = runResolverTestDateTieBreak()

        let results: [(String, Bool)] = [
            ("TEST 1 boundary math",                 t1),
            ("TEST 2 pace strings",                  t2),
            ("TEST 3 peak >= 1.035×CS reaches Sprint", t3),
            ("TEST 4 peak < 1.035×CS clamps sprint",  t4),
            ("TEST 5 invalid CS returns nil",         t5),
            ("TEST 6 invalid peak falls back",       t6),
            ("TEST 7 sourceTrialNumber round-trips",  t7),
            ("TEST 8a resolver trial-1 only → nil",  t8a),
            ("TEST 8b resolver trial-2 clean wins",  t8b),
            ("TEST 8c resolver trial-3 beats trial-2", t8c),
            ("TEST 8d resolver learning flag → nil", t8d),
            ("TEST 8e resolver learning bypassed by clean", t8e),
            ("TEST 8f resolver empty array → nil",  t8f),
            ("TEST 8g resolver testDate tie-break", t8g),
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
