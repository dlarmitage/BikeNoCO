import CoreLocation
import Combine

enum RecordingState: Equatable {
    case idle
    case recording
    case finished(RideSession)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.recording, .recording): return true
        case (.finished, .finished): return true
        default: return false
        }
    }
}

@MainActor
final class RideRecorder: NSObject, ObservableObject {
    @Published var state: RecordingState = .idle
    @Published private(set) var isManuallyPaused = false
    @Published private(set) var isAutoPaused = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var liveDistanceMeters: Double = 0
    @Published var liveSpeedMPS: Double = 0

    var isPaused: Bool { isManuallyPaused || isAutoPaused }

    private var trackPoints: [TrackPoint] = []
    private var startDate: Date?
    private var activeSegmentStart: Date?
    private var accumulatedActiveTime: TimeInterval = 0
    private var stationarySince: Date?
    private var movingSince: Date?
    private var lastKnownSpeedMPS: Double = 0
    private var lastLocationUpdate: Date?
    private var timer: Timer?
    private let manager = CLLocationManager()

    /// Below ~1 mph — treat as stopped (filters GPS jitter at a standstill).
    private static let pauseSpeedMPS: Double = 0.5
    /// Above ~2 mph — treat as riding again after an automatic pause.
    private static let resumeSpeedMPS: Double = 1.0
    /// Above ~5 mph — confirms cycling resumed after a manual pause (ignores walking).
    private static let manualResumeSpeedMPS: Double = 2.2
    /// Seconds of low speed before auto-pausing.
    private static let pauseDelay: TimeInterval = 8
    /// Seconds of movement before auto-resuming.
    private static let resumeDelay: TimeInterval = 3
    /// Minimum displacement to confirm movement when speed is unavailable.
    private static let resumeMovementMeters: Double = 5
    private static let recordingDistanceFilter: CLLocationDistance = 5

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    func startRecording() {
        guard state != .recording else { return }
        manager.requestWhenInUseAuthorization()
        trackPoints = []
        liveDistanceMeters = 0
        liveSpeedMPS = 0
        elapsedTime = 0
        resetPauseTracking()
        let now = Date()
        startDate = now
        activeSegmentStart = now
        manager.distanceFilter = Self.recordingDistanceFilter
        manager.startUpdatingLocation()
        state = .recording

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickTimer()
            }
        }
    }

    /// Manual pause/resume — also resumes from an automatic stop at a light.
    func toggleManualPause() {
        guard case .recording = state else { return }
        if isPaused {
            resumeRecording()
        } else {
            enterManualPause()
        }
    }

    func stopRecording() {
        manager.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil

        let end = Date()
        let start = startDate ?? end
        let movingDuration = activeElapsedTime(at: end)
        let session = RideSession.calculate(
            points: trackPoints, start: start, end: end, movingDuration: movingDuration
        )
        resetPauseTracking()
        state = .finished(session)
    }

    func discardAndReset() {
        manager.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil
        trackPoints = []
        liveDistanceMeters = 0
        liveSpeedMPS = 0
        elapsedTime = 0
        resetPauseTracking()
        state = .idle
    }

    private func tickTimer() {
        guard case .recording = state else { return }
        elapsedTime = activeElapsedTime(at: Date())

        guard !isPaused else { return }
        guard let lastUpdate = lastLocationUpdate else { return }
        let idleDuration = Date().timeIntervalSince(lastUpdate)
        guard idleDuration >= Self.pauseDelay else { return }
        guard lastKnownSpeedMPS < Self.pauseSpeedMPS else { return }
        enterAutoPause()
    }

    private func activeElapsedTime(at date: Date) -> TimeInterval {
        var total = accumulatedActiveTime
        if !isPaused, let segmentStart = activeSegmentStart {
            total += date.timeIntervalSince(segmentStart)
        }
        return total
    }

    private func enterManualPause() {
        guard !isPaused else { return }
        suspendRecording()
        isManuallyPaused = true
    }

    private func enterAutoPause() {
        guard !isPaused else { return }
        suspendRecording()
        isAutoPaused = true
    }

    private func suspendRecording() {
        if let segmentStart = activeSegmentStart {
            accumulatedActiveTime += Date().timeIntervalSince(segmentStart)
            activeSegmentStart = nil
        }
        liveSpeedMPS = 0
        stationarySince = nil
        movingSince = nil
        manager.distanceFilter = kCLDistanceFilterNone
    }

    private func resumeRecording() {
        guard isPaused else { return }
        isManuallyPaused = false
        isAutoPaused = false
        activeSegmentStart = Date()
        movingSince = nil
        stationarySince = nil
        manager.distanceFilter = Self.recordingDistanceFilter
    }

    private func resetPauseTracking() {
        activeSegmentStart = nil
        accumulatedActiveTime = 0
        stationarySince = nil
        movingSince = nil
        lastKnownSpeedMPS = 0
        lastLocationUpdate = nil
        isManuallyPaused = false
        isAutoPaused = false
    }

    private func tryAutoResume(speed: Double, movedFromTrack: Double) {
        guard isPaused else { return }
        let isMoving: Bool
        if isManuallyPaused {
            isMoving = speed >= Self.manualResumeSpeedMPS
        } else {
            isMoving = speed >= Self.resumeSpeedMPS || movedFromTrack >= Self.resumeMovementMeters
        }
        if isMoving {
            if movingSince == nil { movingSince = Date() }
            if Date().timeIntervalSince(movingSince!) >= Self.resumeDelay {
                resumeRecording()
            }
        } else {
            movingSince = nil
        }
    }

    private func effectiveSpeed(for location: CLLocation, previous: CLLocation?) -> Double {
        if location.speed >= 0 { return location.speed }
        guard let previous else { return 0 }
        let dt = location.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return 0 }
        return location.distance(from: previous) / dt
    }

    private func evaluateMotion(at location: CLLocation) {
        let speed = effectiveSpeed(for: location, previous: lastProcessedLocation(for: location))
        lastKnownSpeedMPS = speed
        lastLocationUpdate = location.timestamp

        if isPaused {
            let movedFromTrack = movementFromLastTrackPoint(to: location)
            tryAutoResume(speed: speed, movedFromTrack: movedFromTrack)
            return
        }

        liveSpeedMPS = speed

        if speed < Self.pauseSpeedMPS {
            if stationarySince == nil { stationarySince = Date() }
            if Date().timeIntervalSince(stationarySince!) >= Self.pauseDelay {
                enterAutoPause()
            }
        } else {
            stationarySince = nil
        }
    }

    private func lastProcessedLocation(for location: CLLocation) -> CLLocation? {
        guard let last = trackPoints.last else { return nil }
        return CLLocation(
            coordinate: last.coordinate,
            altitude: last.altitude,
            horizontalAccuracy: last.horizontalAccuracy,
            verticalAccuracy: last.verticalAccuracy,
            timestamp: last.timestamp
        )
    }

    private func movementFromLastTrackPoint(to location: CLLocation) -> Double {
        guard let last = trackPoints.last else { return 0 }
        let lastLocation = CLLocation(
            latitude: last.coordinate.latitude,
            longitude: last.coordinate.longitude
        )
        return location.distance(from: lastLocation)
    }
}

extension RideRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let newPoints = locations
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }
            .map {
                TrackPoint(
                    coordinate: $0.coordinate,
                    altitude: $0.altitude,
                    speed: $0.speed,
                    timestamp: $0.timestamp,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    verticalAccuracy: $0.verticalAccuracy
                )
            }
        guard !newPoints.isEmpty else { return }

        Task { @MainActor in
            guard case .recording = self.state else { return }
            for point in newPoints {
                let location = CLLocation(
                    coordinate: point.coordinate,
                    altitude: point.altitude,
                    horizontalAccuracy: point.horizontalAccuracy,
                    verticalAccuracy: point.verticalAccuracy,
                    timestamp: point.timestamp
                )
                self.evaluateMotion(at: location)

                guard !self.isPaused else { continue }

                if !self.trackPoints.isEmpty, let last = self.trackPoints.last {
                    let a = CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
                    let b = location
                    self.liveDistanceMeters += a.distance(from: b)
                }
                self.trackPoints.append(point)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
