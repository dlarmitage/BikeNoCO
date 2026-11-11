import XCTest
import CoreLocation
@testable import BikeNoCo

final class ElevationCalculatorTests: XCTestCase {

    func testOutAndBackReportsClimbNotNetZero() {
        // Up ~91.4 m (300 ft), then back down to the start.
        let climbMeters = 300.0 / 3.28084
        var altitudes: [Double] = []
        for step in 0...20 {
            altitudes.append(1_500 + climbMeters * Double(step) / 20.0)
        }
        for step in 1...20 {
            altitudes.append(1_500 + climbMeters * Double(20 - step) / 20.0)
        }

        let result = ElevationCalculator.cumulative(altitudes: altitudes, thresholdMeters: 3.0)

        XCTAssertEqual(result.gainMeters, climbMeters, accuracy: 1.0)
        XCTAssertEqual(result.lossMeters, climbMeters, accuracy: 1.0)
        XCTAssertGreaterThan(result.gainMeters, 80)
        // Net change is ~0, but gain must still reflect the climb.
        XCTAssertEqual(
            altitudes.last! - altitudes.first!,
            0,
            accuracy: 0.01,
            "fixture is a true out-and-back"
        )
    }

    func testGPSKeepsMediocreVerticalAccuracySummitPoints() {
        let climb = 90.0
        // Typical phone GPS: verticalAccuracy often > 15 m. Old filter dropped these.
        let samples: [(Double, Double)] = [
            (1_500, 20),
            (1_500 + climb * 0.25, 22),
            (1_500 + climb * 0.5, 25),
            (1_500 + climb * 0.75, 18),
            (1_500 + climb, 24),
            (1_500 + climb * 0.5, 21),
            (1_500, 23)
        ]

        let result = ElevationCalculator.fromGPS(altitudesWithAccuracy: samples)

        XCTAssertEqual(result.gainMeters, climb, accuracy: 5.0)
        XCTAssertEqual(result.lossMeters, climb, accuracy: 5.0)
    }

    func testFlatRideStaysNearZero() {
        let altitudes = Array(repeating: 1_520.0, count: 40)
        let result = ElevationCalculator.cumulative(altitudes: altitudes, thresholdMeters: 3.0)
        XCTAssertEqual(result.gainMeters, 0, accuracy: 0.01)
        XCTAssertEqual(result.lossMeters, 0, accuracy: 0.01)
    }

    func testSmallJitterBelowThresholdIgnored() {
        // ±1 m noise around a plateau should not invent climbing.
        var altitudes: [Double] = []
        for i in 0..<30 {
            altitudes.append(1_500 + (i % 2 == 0 ? 0.8 : -0.8))
        }
        let result = ElevationCalculator.cumulative(altitudes: altitudes, thresholdMeters: 3.0)
        XCTAssertEqual(result.gainMeters, 0, accuracy: 0.01)
        XCTAssertEqual(result.lossMeters, 0, accuracy: 0.01)
    }

    func testRideSessionCalculateUsesCumulativeAscent() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let climb = 91.44
        var points: [TrackPoint] = []
        for i in 0...20 {
            points.append(
                TrackPoint(
                    coordinate: CLLocationCoordinate2D(
                        latitude: 40.58 + Double(i) * 0.0001,
                        longitude: -105.08
                    ),
                    altitude: 1_500 + climb * Double(i) / 20.0,
                    speed: 5,
                    timestamp: start.addingTimeInterval(Double(i) * 5),
                    horizontalAccuracy: 5,
                    verticalAccuracy: 20
                )
            )
        }
        for i in 1...20 {
            points.append(
                TrackPoint(
                    coordinate: CLLocationCoordinate2D(
                        latitude: 40.582 + Double(i) * 0.0001,
                        longitude: -105.08
                    ),
                    altitude: 1_500 + climb * Double(20 - i) / 20.0,
                    speed: 5,
                    timestamp: start.addingTimeInterval(Double(20 + i) * 5),
                    horizontalAccuracy: 5,
                    verticalAccuracy: 20
                )
            )
        }

        let session = RideSession.calculate(
            points: points,
            start: start,
            end: start.addingTimeInterval(200),
            movingDuration: 200
        )

        XCTAssertEqual(session.elevationGainMeters, climb, accuracy: 5.0)
        XCTAssertEqual(session.elevationLossMeters, climb, accuracy: 5.0)
        XCTAssertEqual(session.elevationGainFeet, 300, accuracy: 20)
    }

    func testEmptyBarometerOverrideFallsBackToGPS() {
        let start = Date()
        let points = [
            TrackPoint(
                coordinate: CLLocationCoordinate2D(latitude: 40.58, longitude: -105.08),
                altitude: 1_500, speed: 5, timestamp: start,
                horizontalAccuracy: 5, verticalAccuracy: 10
            ),
            TrackPoint(
                coordinate: CLLocationCoordinate2D(latitude: 40.581, longitude: -105.08),
                altitude: 1_560, speed: 5, timestamp: start.addingTimeInterval(60),
                horizontalAccuracy: 5, verticalAccuracy: 10
            )
        ]
        // Flat barometer override must not wipe real GPS climb.
        let session = RideSession.calculate(
            points: points,
            start: start,
            end: start.addingTimeInterval(60),
            elevationOverride: (gain: 0, loss: 0)
        )
        XCTAssertEqual(session.elevationGainMeters, 60, accuracy: 1.0)
        XCTAssertEqual(session.elevationLossMeters, 0, accuracy: 1.0)
    }
}
