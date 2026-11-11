import Foundation

/// Cumulative ascent / descent for exercise stats — not net elevation change.
///
/// Going up 100 m and back down must report ~100 m gain and ~100 m loss, even when
/// start and end altitude match.
enum ElevationCalculator {
    struct Result: Equatable, Sendable {
        var gainMeters: Double
        var lossMeters: Double

        var totalChangeMeters: Double { gainMeters + lossMeters }
    }

    /// Hysteresis accumulation: ignore jitter smaller than `thresholdMeters`, but once
    /// altitude moves past the threshold from the last committed altitude, add the full
    /// step to gain or loss. This preserves climbs that would vanish if noisy summit
    /// points were filtered away or if each consecutive GPS step stayed under a floor.
    static func cumulative(
        altitudes: [Double],
        thresholdMeters: Double
    ) -> Result {
        guard let first = altitudes.first, altitudes.count > 1, thresholdMeters > 0 else {
            return Result(gainMeters: 0, lossMeters: 0)
        }

        var gain = 0.0
        var loss = 0.0
        var committed = first

        for altitude in altitudes.dropFirst() {
            let diff = altitude - committed
            if diff >= thresholdMeters {
                gain += diff
                committed = altitude
            } else if diff <= -thresholdMeters {
                loss += -diff
                committed = altitude
            }
        }

        return Result(gainMeters: gain, lossMeters: loss)
    }

    /// GPS path: keep any sample with a reported vertical accuracy (≥ 0). Do not drop
    /// mid-climb points just because accuracy is mediocre — that turns out-and-backs into
    /// ~0 gain when only start/end remain.
    ///
    /// Hysteresis alone rejects phone GPS jitter; a moving average would flatten real
    /// summits on sparse tracks and under-report climb.
    static func fromGPS(
        altitudesWithAccuracy: [(altitude: Double, verticalAccuracy: Double)],
        thresholdMeters: Double = 3.0
    ) -> Result {
        let altitudes = altitudesWithAccuracy.compactMap { sample -> Double? in
            guard sample.verticalAccuracy >= 0 else { return nil }
            return sample.altitude
        }
        guard altitudes.count > 1 else {
            return Result(gainMeters: 0, lossMeters: 0)
        }
        return cumulative(altitudes: altitudes, thresholdMeters: thresholdMeters)
    }

    /// Barometer path: denser, quieter samples — smaller threshold.
    static func fromBarometer(
        relativeAltitudes: [Double],
        thresholdMeters: Double = 0.5
    ) -> Result? {
        guard relativeAltitudes.count > 1 else { return nil }
        return cumulative(altitudes: relativeAltitudes, thresholdMeters: thresholdMeters)
    }
}
