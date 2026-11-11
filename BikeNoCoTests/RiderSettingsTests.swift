import XCTest
import CoreLocation
@testable import BikeNoCo

final class RiderSettingsTests: XCTestCase {

    func testMountainBikeCaloriesHigherThanRoadAtSameEffort() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [
            TrackPoint(
                coordinate: CLLocationCoordinate2D(latitude: 40.58, longitude: -105.08),
                altitude: 1_500, speed: 5.5, timestamp: start,
                horizontalAccuracy: 5, verticalAccuracy: 5
            ),
            TrackPoint(
                coordinate: CLLocationCoordinate2D(latitude: 40.582, longitude: -105.08),
                altitude: 1_500, speed: 5.5, timestamp: start.addingTimeInterval(600),
                horizontalAccuracy: 5, verticalAccuracy: 5
            )
        ]

        let road = RideSession.calculate(
            points: points,
            start: start,
            end: start.addingTimeInterval(600),
            movingDuration: 600,
            weightKilograms: 70,
            bikeType: .road
        )
        let mountain = RideSession.calculate(
            points: points,
            start: start,
            end: start.addingTimeInterval(600),
            movingDuration: 600,
            weightKilograms: 70,
            bikeType: .mountain
        )
        let ebike = RideSession.calculate(
            points: points,
            start: start,
            end: start.addingTimeInterval(600),
            movingDuration: 600,
            weightKilograms: 70,
            bikeType: .ebike
        )

        XCTAssertGreaterThan(mountain.estimatedCalories, road.estimatedCalories)
        XCTAssertLessThan(ebike.estimatedCalories, road.estimatedCalories)
        XCTAssertEqual(
            mountain.estimatedCalories / road.estimatedCalories,
            BikeType.mountain.calorieMultiplier,
            accuracy: 0.001
        )
    }
}
