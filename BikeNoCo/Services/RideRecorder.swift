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
    @Published var elapsedTime: TimeInterval = 0
    @Published var liveDistanceMeters: Double = 0
    @Published var liveSpeedMPS: Double = 0

    private var trackPoints: [TrackPoint] = []
    private var startDate: Date?
    private var timer: Timer?
    private let manager = CLLocationManager()

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
        startDate = Date()
        manager.startUpdatingLocation()
        state = .recording

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startDate else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    func stopRecording() {
        manager.stopUpdatingLocation()
        timer?.invalidate()
        timer = nil

        let end = Date()
        let start = startDate ?? end
        let session = RideSession.calculate(points: trackPoints, start: start, end: end)
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
        state = .idle
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
            if !self.trackPoints.isEmpty, let last = self.trackPoints.last, let first = newPoints.first {
                let a = CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
                let b = CLLocation(latitude: first.coordinate.latitude, longitude: first.coordinate.longitude)
                self.liveDistanceMeters += a.distance(from: b)
            }
            self.trackPoints.append(contentsOf: newPoints)

            if let speed = newPoints.last?.speed, speed >= 0 {
                self.liveSpeedMPS = speed
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
