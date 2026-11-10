import CoreLocation
import Combine

/// Shared location source for ride recording and turn-by-turn navigation.
///
/// Owns a single `CLLocationManager`. Tests and the DEBUG ride simulator can
/// drive updates via `inject(_:)` / `startSimulation(_:)` without touching Core Location.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var isUpdating = false
    /// True while a DEBUG/test simulation owns the location stream.
    @Published private(set) var isSimulating = false

    private let locationSubject = PassthroughSubject<CLLocation, Never>()
    var locations: AnyPublisher<CLLocation, Never> {
        locationSubject.eraseToAnyPublisher()
    }

    private let manager = CLLocationManager()
    private var simulationCancellable: AnyCancellable?

    /// Consumers that need continuous GPS (recording, navigation).
    private var activeConsumers: Set<ObjectIdentifier> = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Request When In Use authorization if needed.
    func requestAuthorizationIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    /// Begin receiving live (or simulated) location updates for `consumer`.
    func startUpdating(for consumer: AnyObject) {
        let id = ObjectIdentifier(consumer)
        let wasEmpty = activeConsumers.isEmpty
        activeConsumers.insert(id)
        guard wasEmpty else { return }
        beginUpdatesIfNeeded()
    }

    /// Stop updates for `consumer`. Hardware updates stop when the last consumer leaves.
    func stopUpdating(for consumer: AnyObject) {
        let id = ObjectIdentifier(consumer)
        activeConsumers.remove(id)
        guard activeConsumers.isEmpty else { return }
        endUpdates()
    }

    /// Push a single fix (tests / one-shot injection). Does not start the hardware manager.
    func inject(_ location: CLLocation) {
        publish(location)
    }

    /// Drive the provider from an external publisher (DEBUG ride simulator, unit tests).
    /// Suspends hardware updates while the simulation is active.
    func startSimulation(_ publisher: AnyPublisher<CLLocation, Never>) {
        stopSimulation()
        isSimulating = true
        if isUpdating {
            manager.stopUpdatingLocation()
        }
        simulationCancellable = publisher.sink { [weak self] location in
            Task { @MainActor [weak self] in
                self?.publish(location)
            }
        }
    }

    func stopSimulation() {
        simulationCancellable?.cancel()
        simulationCancellable = nil
        guard isSimulating else { return }
        isSimulating = false
        if isUpdating, !activeConsumers.isEmpty {
            manager.startUpdatingLocation()
        }
    }

    private func beginUpdatesIfNeeded() {
        isUpdating = true
        requestAuthorizationIfNeeded()
        guard !isSimulating else { return }
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.startUpdatingLocation()
    }

    private func endUpdates() {
        isUpdating = false
        stopSimulation()
        manager.stopUpdatingLocation()
    }

    private func publish(_ location: CLLocation) {
        latestLocation = location
        locationSubject.send(location)
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let filtered = locations.filter { $0.horizontalAccuracy >= 0 }
        guard let last = filtered.last else { return }
        Task { @MainActor in
            // Ignore hardware while a simulation owns the stream.
            guard !self.isSimulating else { return }
            for location in filtered {
                self.publish(location)
            }
            // Prefer the most recent as `latestLocation` (already set by publish).
            _ = last
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
