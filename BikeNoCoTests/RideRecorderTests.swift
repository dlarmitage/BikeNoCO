import XCTest
import CoreLocation
@testable import BikeNoCo

@MainActor
final class RideRecorderTests: XCTestCase {
    private var clock: Date!
    private var provider: LocationProvider!
    private var recorder: RideRecorder!

    override func setUp() async throws {
        clock = Date(timeIntervalSince1970: 1_700_000_000)
        provider = LocationProvider()
        var timing = RideRecorderTiming.default
        timing.pauseDelay = 2
        timing.resumeDelay = 1
        recorder = RideRecorder(
            locationProvider: provider,
            timing: timing,
            now: { [unowned self] in self.clock }
        )
    }

    func testAutoPauseAfterSustainedLowSpeed() {
        recorder.startRecording()
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertFalse(recorder.isPaused)

        inject(latitude: 40.58, longitude: -105.08, speed: 5.0, accuracy: 5)
        XCTAssertFalse(recorder.isAutoPaused)

        // Stationary for longer than pauseDelay.
        inject(latitude: 40.58, longitude: -105.08, speed: 0.1, accuracy: 5)
        clock = clock.addingTimeInterval(2.1)
        inject(latitude: 40.58, longitude: -105.08, speed: 0.1, accuracy: 5)

        XCTAssertTrue(recorder.isAutoPaused)
        XCTAssertTrue(recorder.isPaused)
        XCTAssertEqual(recorder.liveSpeedMPS, 0, accuracy: 0.01)
    }

    func testAutoResumeAfterMovingAgain() {
        recorder.startRecording()
        inject(latitude: 40.58, longitude: -105.08, speed: 5.0, accuracy: 5)
        inject(latitude: 40.58, longitude: -105.08, speed: 0.0, accuracy: 5)
        clock = clock.addingTimeInterval(2.1)
        inject(latitude: 40.58, longitude: -105.08, speed: 0.0, accuracy: 5)
        XCTAssertTrue(recorder.isAutoPaused)

        // Resume requires resumeDelay of sustained movement.
        inject(latitude: 40.5801, longitude: -105.08, speed: 2.0, accuracy: 5)
        XCTAssertTrue(recorder.isAutoPaused)
        clock = clock.addingTimeInterval(1.1)
        inject(latitude: 40.5802, longitude: -105.08, speed: 2.0, accuracy: 5)

        XCTAssertFalse(recorder.isAutoPaused)
        XCTAssertFalse(recorder.isPaused)
    }

    func testPausedDoesNotAppendTrackDistance() {
        recorder.startRecording()
        inject(latitude: 40.58, longitude: -105.08, speed: 5.0, accuracy: 5)
        inject(latitude: 40.58005, longitude: -105.08, speed: 5.0, accuracy: 5)
        let distanceBeforePause = recorder.liveDistanceMeters
        XCTAssertGreaterThan(distanceBeforePause, 0)

        inject(latitude: 40.58005, longitude: -105.08, speed: 0.0, accuracy: 5)
        clock = clock.addingTimeInterval(2.1)
        inject(latitude: 40.58005, longitude: -105.08, speed: 0.0, accuracy: 5)
        XCTAssertTrue(recorder.isAutoPaused)

        // Large movement while paused should not grow recorded distance.
        inject(latitude: 40.581, longitude: -105.08, speed: 0.0, accuracy: 5)
        XCTAssertEqual(recorder.liveDistanceMeters, distanceBeforePause, accuracy: 0.01)
    }

    func testManualPauseRequiresFasterResumeSpeed() {
        recorder.startRecording()
        inject(latitude: 40.58, longitude: -105.08, speed: 5.0, accuracy: 5)
        recorder.toggleManualPause()
        XCTAssertTrue(recorder.isManuallyPaused)

        // ~2 mph is enough for auto-resume but not manual.
        inject(latitude: 40.5801, longitude: -105.08, speed: 1.0, accuracy: 5)
        clock = clock.addingTimeInterval(1.1)
        inject(latitude: 40.5802, longitude: -105.08, speed: 1.0, accuracy: 5)
        XCTAssertTrue(recorder.isManuallyPaused)

        inject(latitude: 40.5803, longitude: -105.08, speed: 3.0, accuracy: 5)
        clock = clock.addingTimeInterval(1.1)
        inject(latitude: 40.5804, longitude: -105.08, speed: 3.0, accuracy: 5)
        XCTAssertFalse(recorder.isPaused)
    }

    func testSharedProviderKeepsPublishingWhileRecorderAutoPaused() {
        var receivedWhilePaused = 0
        let extra = provider.locations.sink { [weak self] _ in
            guard let self, self.recorder.isAutoPaused else { return }
            receivedWhilePaused += 1
        }
        defer { extra.cancel() }

        recorder.startRecording()
        inject(latitude: 40.58, longitude: -105.08, speed: 5.0, accuracy: 5)
        inject(latitude: 40.58, longitude: -105.08, speed: 0.0, accuracy: 5)
        clock = clock.addingTimeInterval(2.1)
        inject(latitude: 40.58, longitude: -105.08, speed: 0.0, accuracy: 5)
        XCTAssertTrue(recorder.isAutoPaused)

        inject(latitude: 40.58001, longitude: -105.08, speed: 0.0, accuracy: 5)
        inject(latitude: 40.58002, longitude: -105.08, speed: 0.0, accuracy: 5)
        XCTAssertGreaterThanOrEqual(receivedWhilePaused, 2)
    }

    // MARK: - Helpers

    private func inject(
        latitude: Double,
        longitude: Double,
        speed: Double,
        accuracy: Double
    ) {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 1500,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 5,
            course: 0,
            speed: speed,
            timestamp: clock
        )
        provider.inject(location)
    }
}
