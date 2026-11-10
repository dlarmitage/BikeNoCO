import Foundation
import CoreLocation
import Combine
import UIKit

/// Main-actor façade over `NavigationEngine`, voice, haptics, and screen-awake behavior.
@MainActor
final class NavigationController: ObservableObject {
    private static let keepAwakeKey = "navigationKeepScreenAwake"

    @Published private(set) var state: NavigationState = .idle
    @Published private(set) var progress: RouteProgress?
    @Published private(set) var nextManeuver: Maneuver?
    @Published private(set) var remainingDistanceMeters: Double = 0
    @Published private(set) var remainingRouteCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var etaDate: Date?
    @Published private(set) var isNavigating = false
    @Published var keepScreenAwake: Bool {
        didSet { UserDefaults.standard.set(keepScreenAwake, forKey: Self.keepAwakeKey) }
    }

    let voice = VoiceGuidance()

    var isSimulating: Bool { locationProvider.isSimulating }

    private let locationProvider: LocationProvider
    private let engine = NavigationEngine()
    private var locationCancellable: AnyCancellable?
    private var voiceCancellable: AnyCancellable?
    private var previousIdleTimerDisabled = false
    private var idleTimerOwned = false
    private var activeRouteCoordinates: [CLLocationCoordinate2D] = []

    init(locationProvider: LocationProvider) {
        self.locationProvider = locationProvider
        if UserDefaults.standard.object(forKey: Self.keepAwakeKey) == nil {
            keepScreenAwake = true
        } else {
            keepScreenAwake = UserDefaults.standard.bool(forKey: Self.keepAwakeKey)
        }

        voiceCancellable = voice.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        engine.onEvent { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    var isMuted: Bool {
        get { voice.isMuted }
        set { voice.isMuted = newValue }
    }

    func start(
        route: PlannedRoute,
        graph: BikeNetworkGraph,
        profile: RoutingProfile = .default
    ) {
        let destination = route.destination
        engine.start(
            route: route,
            maneuvers: ManeuverBuilder.build(from: route),
            rerouteHandler: { origin, _ in
                await Task.detached(priority: .userInitiated) {
                    RouteFinder.route(from: origin, to: destination, graph: graph, profile: profile)
                }.value
            }
        )
        activeRouteCoordinates = route.coordinates
        remainingRouteCoordinates = route.coordinates
        latestLocation = nil
        isNavigating = true
        subscribe()
        locationProvider.startUpdating(for: self)
        applyIdleTimer(enabled: true)
    }

    func end() {
        engine.stop()
        unsubscribe()
        locationProvider.stopUpdating(for: self)
        locationProvider.stopSimulation()
        voice.stop()
        isNavigating = false
        progress = nil
        nextManeuver = nil
        remainingDistanceMeters = 0
        remainingRouteCoordinates = []
        activeRouteCoordinates = []
        latestLocation = nil
        etaDate = nil
        state = .idle
        applyIdleTimer(enabled: false)
    }

    #if DEBUG
    func startSimulatedRide(
        route: PlannedRoute,
        graph: BikeNetworkGraph,
        injectDetour: Bool,
        profile: RoutingProfile = .default
    ) {
        start(route: route, graph: graph, profile: profile)
        let publisher = RideSimulator.publisher(
            coordinates: route.coordinates,
            speedMPS: RideSimulator.defaultSpeedMPS,
            injectDetour: injectDetour
        )
        locationProvider.startSimulation(publisher)
    }
    #endif

    private func subscribe() {
        locationCancellable = locationProvider.locations.sink { [weak self] location in
            guard let self else { return }
            self.latestLocation = location
            self.engine.update(location: location)
        }
    }

    private func unsubscribe() {
        locationCancellable?.cancel()
        locationCancellable = nil
    }

    private func handle(_ event: NavigationEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
            isNavigating = newState != .idle
            if newState == .idle {
                applyIdleTimer(enabled: false)
            }
        case .prompt(let text, _):
            NSLog("[BikeNoCo Nav] %@", text)
            voice.speak(text)
        case .haptic(let kind):
            NavigationHaptics.play(kind)
        case .progress(let progress):
            self.progress = progress
            nextManeuver = progress.nextManeuver
            remainingDistanceMeters = progress.remainingDistance
            if !activeRouteCoordinates.isEmpty {
                remainingRouteCoordinates = PolylineSlicer.remaining(
                    coordinates: activeRouteCoordinates,
                    fromDistanceAlong: progress.distanceAlongRoute
                )
            }
            updateETA(remaining: progress.remainingDistance)
            // After a successful reroute the engine swaps routes; refresh the source polyline.
            if let route = engine.route, route.coordinates.count != activeRouteCoordinates.count
                || !Self.sameCoordinates(route.coordinates, activeRouteCoordinates) {
                activeRouteCoordinates = route.coordinates
                remainingRouteCoordinates = PolylineSlicer.remaining(
                    coordinates: activeRouteCoordinates,
                    fromDistanceAlong: progress.distanceAlongRoute
                )
            }
        }
    }

    private static func sameCoordinates(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices {
            if abs(a[i].latitude - b[i].latitude) > 1e-8
                || abs(a[i].longitude - b[i].longitude) > 1e-8 {
                return false
            }
        }
        return true
    }

    private func updateETA(remaining: Double) {
        let speed = max(engine.rollingSpeedMPS, 3.0) // floor ~6.7 mph so ETA isn't infinite when stopped
        let seconds = remaining / speed
        etaDate = Date().addingTimeInterval(seconds)
    }

    private func applyIdleTimer(enabled: Bool) {
        guard keepScreenAwake else {
            if idleTimerOwned {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
                idleTimerOwned = false
            }
            return
        }
        if enabled {
            if !idleTimerOwned {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
                idleTimerOwned = true
            }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if idleTimerOwned {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            idleTimerOwned = false
        }
    }
}
