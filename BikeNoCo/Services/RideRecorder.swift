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

struct RideRecorderTiming: Equatable, Sendable {
    /// Below ~1 mph — treat as stopped (filters GPS jitter at a standstill).
    var pauseSpeedMPS: Double = 0.5
    /// Above ~2 mph — treat as riding again after an automatic pause.
    var resumeSpeedMPS: Double = 1.0
    /// Above ~5 mph — confirms cycling resumed after a manual pause (ignores walking).
    var manualResumeSpeedMPS: Double = 2.2
    /// Seconds of low speed before auto-pausing.
    var pauseDelay: TimeInterval = 8
    /// Seconds of movement before auto-resuming.
    var resumeDelay: TimeInterval = 3
    /// Minimum displacement to confirm movement when speed is unavailable.
    var resumeMovementMeters: Double = 5
    /// Minimum spacing between recorded track points while actively recording.
    var recordingDistanceFilter: CLLocationDistance = 5

    static let `default` = RideRecorderTiming()
}

@MainActor
final class RideRecorder: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published private(set) var isManuallyPaused = false
    @Published private(set) var isAutoPaused = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var liveDistanceMeters: Double = 0
    @Published var liveSpeedMPS: Double = 0

    var isPaused: Bool { isManuallyPaused || isAutoPaused }

    private let locationProvider: LocationProvider
    private let timing: RideRecorderTiming
    private let now: () -> Date
    private var locationCancellable: AnyCancellable?
    private var trackPoints: [TrackPoint] = []
    private var startDate: Date?
    private var activeSegmentStart: Date?
    private var accumulatedActiveTime: TimeInterval = 0
    private var stationarySince: Date?
    private var movingSince: Date?
    private var lastKnownSpeedMPS: Double = 0
    private var lastLocationUpdate: Date?
    private var timer: Timer?

    init(
        locationProvider: LocationProvider,
        timing: RideRecorderTiming = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.locationProvider = locationProvider
        self.timing = timing
        self.now = now
    }

    func startRecording() {
        guard state != .recording else { return }
        locationProvider.requestAuthorizationIfNeeded()
        trackPoints = []
        liveDistanceMeters = 0
        liveSpeedMPS = 0
        elapsedTime = 0
        resetPauseTracking()
        let start = now()
        startDate = start
        activeSegmentStart = start
        subscribeToLocations()
        locationProvider.startUpdating(for: self)
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
        unsubscribeFromLocations()
        locationProvider.stopUpdating(for: self)
        timer?.invalidate()
        timer = nil

        let end = now()
        let start = startDate ?? end
        let movingDuration = activeElapsedTime(at: end)
        let session = RideSession.calculate(
            points: trackPoints, start: start, end: end, movingDuration: movingDuration
        )
        resetPauseTracking()
        state = .finished(session)
    }

    func discardAndReset() {
        unsubscribeFromLocations()
        locationProvider.stopUpdating(for: self)
        timer?.invalidate()
        timer = nil
        trackPoints = []
        liveDistanceMeters = 0
        liveSpeedMPS = 0
        elapsedTime = 0
        resetPauseTracking()
        state = .idle
    }

    private func subscribeToLocations() {
        locationCancellable = locationProvider.locations.sink { [weak self] location in
            self?.handleLocation(location)
        }
    }

    private func unsubscribeFromLocations() {
        locationCancellable?.cancel()
        locationCancellable = nil
    }

    private func handleLocation(_ location: CLLocation) {
        guard case .recording = state else { return }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50 else { return }

        let point = TrackPoint(
            coordinate: location.coordinate,
            altitude: location.altitude,
            speed: location.speed,
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy
        )

        evaluateMotion(at: location)

        guard !isPaused else { return }

        if let last = trackPoints.last {
            let previous = CLLocation(
                latitude: last.coordinate.latitude,
                longitude: last.coordinate.longitude
            )
            let delta = previous.distance(from: location)
            // Match prior CLLocationManager distanceFilter=5 behavior while recording.
            guard delta >= timing.recordingDistanceFilter else { return }
            liveDistanceMeters += delta
        }
        trackPoints.append(point)
    }

    private func tickTimer() {
        guard case .recording = state else { return }
        let current = now()
        elapsedTime = activeElapsedTime(at: current)

        guard !isPaused else { return }
        guard let lastUpdate = lastLocationUpdate else { return }
        let idleDuration = current.timeIntervalSince(lastUpdate)
        guard idleDuration >= timing.pauseDelay else { return }
        guard lastKnownSpeedMPS < timing.pauseSpeedMPS else { return }
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
            accumulatedActiveTime += now().timeIntervalSince(segmentStart)
            activeSegmentStart = nil
        }
        liveSpeedMPS = 0
        stationarySince = nil
        movingSince = nil
    }

    private func resumeRecording() {
        guard isPaused else { return }
        isManuallyPaused = false
        isAutoPaused = false
        activeSegmentStart = now()
        movingSince = nil
        stationarySince = nil
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
            isMoving = speed >= timing.manualResumeSpeedMPS
        } else {
            isMoving = speed >= timing.resumeSpeedMPS || movedFromTrack >= timing.resumeMovementMeters
        }
        if isMoving {
            if movingSince == nil { movingSince = now() }
            if let since = movingSince, now().timeIntervalSince(since) >= timing.resumeDelay {
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

        if speed < timing.pauseSpeedMPS {
            if stationarySince == nil { stationarySince = now() }
            if let since = stationarySince, now().timeIntervalSince(since) >= timing.pauseDelay {
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
