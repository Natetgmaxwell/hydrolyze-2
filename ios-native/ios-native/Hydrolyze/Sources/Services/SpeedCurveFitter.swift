import Foundation

/// SpeedCurveFitter — power-law fit of personal bests.
///
/// Model: speed = a × distance^b in log-log space, where
///     speed = distance / time_ms × 1000 (m/s).
///
/// Fitting:
///   - 1 PB → fix b = -0.165 (swimming literature, the standard fatigue
///     factor), solve for a.
///   - 2+ PBs → OLS regression in log-log space, estimate both a and b.
///     If b comes out >= 0 (impossible — speed can't grow with distance
///     in real swimmers), fall back to single-PB at the median distance.
///
/// Then predict: time(d) = 1000 × d / speed(d).
///
/// Used by `HistoricalTimePredictor` Layer 2 (the speed-curve fallback
/// when no recorded data exists for the exact combo).
struct SpeedCurve: Equatable, Sendable {
    let a: Double               // log-log intercept
    let b: Double               // log-log slope (negative for swimmers)
    let fitDistances: [Int]     // PB distances used to fit this curve
    let fitMethod: Method

    enum Method: String, Codable, Sendable, Equatable {
        /// 1 PB — slope is fixed at the literature default.
        case singlePbFixedSlope
        /// 2+ PBs — slope was fit by OLS.
        case olsRegression
    }
}

enum SpeedCurveFitter {
    /// The default slope for the 1-PB case. Per the v2 design:
    /// each doubling of distance costs ~10.8% in speed.
    /// This corresponds to exponent 1.06 in the Riegel formula
    /// (T2 = T1 × (D2/D1)^1.06) — same curve, expressed in speed.
    static let defaultSlope: Double = -0.165

    /// Fit a speed curve from PB records for one swimmer + stroke.
    /// Returns nil if no valid PBs.
    static func fitCurve(pbs: [SwimmerPB]) -> SpeedCurve? {
        let valid = pbs.filter { $0.distance > 0 && $0.timeMs > 0 && $0.timeMs < 3_600_000 }
        guard !valid.isEmpty else { return nil }

        if valid.count == 1 {
            return singlePB(valid[0])
        }

        // 2+ PBs: OLS in log-log space
        let xs = valid.map { log(Double($0.distance)) }
        let ys = valid.map { log(Double($0.distance) / Double($0.timeMs) * 1000) }
        let n = Double(valid.count)
        let xMean = xs.reduce(0, +) / n
        let yMean = ys.reduce(0, +) / n

        var ssxx = 0.0
        var ssxy = 0.0
        for i in 0..<valid.count {
            let dx = xs[i] - xMean
            ssxx += dx * dx
            ssxy += dx * (ys[i] - yMean)
        }

        // Degenerate: all PBs at the same distance (or numerical noise)
        if ssxx == 0 {
            return singlePB(valid[0])
        }

        let b = ssxy / ssxx

        // Impossible: speed increases with distance. Fall back to the
        // median PB so we don't return a curve that would predict
        // faster times for longer distances.
        if b >= 0 {
            let mid = valid[valid.count / 2]
            return singlePB(mid)
        }

        let a = yMean - b * xMean
        return SpeedCurve(
            a: a,
            b: b,
            fitDistances: valid.map { $0.distance }.sorted(),
            fitMethod: .olsRegression
        )
    }

    /// Predict expected race-pace time (ms) at target distance.
    /// Returns nil if distance is invalid or the prediction is
    /// physically implausible (20s-90min sanity range from v2).
    static func predictRacePace(curve: SpeedCurve, distance: Int) -> Int? {
        guard distance > 0 else { return nil }
        let speed = exp(curve.a + curve.b * log(Double(distance)))
        let timeMs = Int((Double(distance) / speed * 1000).rounded())
        if timeMs < 20_000 || timeMs > 5_400_000 { return nil }
        return timeMs
    }

    /// Single-PB fit with the literature-default slope.
    private static func singlePB(_ pb: SwimmerPB) -> SpeedCurve {
        let speed = Double(pb.distance) / Double(pb.timeMs) * 1000
        let a = log(speed) - defaultSlope * log(Double(pb.distance))
        return SpeedCurve(
            a: a,
            b: defaultSlope,
            fitDistances: [pb.distance],
            fitMethod: .singlePbFixedSlope
        )
    }
}
