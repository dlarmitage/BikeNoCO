import CoreLocation
import Combine

/// Shared location source for the map puck, ride recording, and turn-by-turn navigation.
///
/// Owns a single `CLLocationManager`. Tests and the DEBUG ride simulator can
/// drive updates via `inject(_:)` / `startSimulation(_:)` without touching Core Location.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    /// Desk-testing origin when the Simulator has no active GPX / custom location.
    static let fortCollinsFallback = CLLocationCoordinate2D(latitude: 40.5853, longitude: -105.0844)

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
    private var fallbackTask: Task<Void, Never>?

    /// Consumers that need continuous GPS (map, recording, navigation).
    private var activeConsumers: Set<ObjectIdentifier> = []
    /// Consumers that also need background delivery (recording / navigation).
    private var backgroundConsumers: Set<ObjectIdentifier> = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
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
    func startUpdating(for consumer: AnyObject, allowsBackground: Bool = false) {
        let id = ObjectIdentifier(consumer)
        let wasEmpty = activeConsumers.isEmpty
        activeConsumers.insert(id)
        if allowsBackground {
            backgroundConsumers.insert(id)
        }
        if wasEmpty {
            beginUpdatesIfNeeded()
        } else {
            updateBackgroundDelivery()
        }
    }

    /// Stop updates for `consumer`. Hardware updates stop when the last consumer leaves.
    func stopUpdating(for consumer: AnyObject) {
        let id = ObjectIdentifier(consumer)
        activeConsumers.remove(id)
        backgroundConsumers.remove(id)
        guard activeConsumers.isEmpty else {
            updateBackgroundDelivery()
            return
        }
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
        fallbackTask?.cancel()
        fallbackTask = nil
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
            scheduleSimulatorFallbackIfNeeded()
        }
    }

    private func beginUpdatesIfNeeded() {
        isUpdating = true
        requestAuthorizationIfNeeded()
        guard !isSimulating else { return }
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        updateBackgroundDelivery()
        manager.startUpdatingLocation()
        // One-shot helps the first puck appear before the continuous stream warms up.
        manager.requestLocation()
        scheduleSimulatorFallbackIfNeeded()
    }

    private func updateBackgroundDelivery() {
        let wantsBackground = !backgroundConsumers.isEmpty
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = wantsBackground
        default:
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    private func scheduleSimulatorFallbackIfNeeded() {
        #if targetEnvironment(simulator)
        fallbackTask?.cancel()
        fallbackTask = Task { @MainActor [weak self] in
            // Give the scheme GPX / Features → Location a moment to deliver a fix.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.isUpdating, !self.isSimulating, self.latestLocation == nil else { return }
            let fallback = CLLocation(
                coordinate: Self.fortCollinsFallback,
                altitude: 0,
                horizontalAccuracy: 15,
                verticalAccuracy: -1,
                course: -1,
                speed: -1,
                timestamp: Date()
            )
            NSLog("[BikeNoCo] Simulator has no GPS fix — placing Fort Collins fallback puck")
            self.publish(fallback)
        }
        #endif
    }

    private func endUpdates() {
        isUpdating = false
        fallbackTask?.cancel()
        fallbackTask = nil
        stopSimulation()
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
    }

    private func publish(_ location: CLLocation) {
        latestLocation = location
        locationSubject.send(location)
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.updateBackgroundDelivery()
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
                if self.isUpdating, !self.isSimulating, !self.activeConsumers.isEmpty {
                    self.manager.startUpdatingLocation()
                    self.manager.requestLocation()
                    self.scheduleSimulatorFallbackIfNeeded()
                }
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let filtered = locations.filter { $0.horizontalAccuracy >= 0 }
        guard !filtered.isEmpty else { return }
        Task { @MainActor in
            // Ignore hardware while a simulation owns the stream.
            guard !self.isSimulating else { return }
            self.fallbackTask?.cancel()
            self.fallbackTask = nil
            for location in filtered {
                self.publish(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[BikeNoCo] LocationProvider error: %@", error.localizedDescription)
        // Still allow the simulator fallback to place a puck when Core Location fails.
        Task { @MainActor in
            self.scheduleSimulatorFallbackIfNeeded()
        }
    }
}
