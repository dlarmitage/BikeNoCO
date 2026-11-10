import Foundation
import CoreLocation

enum NavigationState: Equatable, Sendable {
    case idle
    case navigating
    case offRoute
    case rerouting
    case arrived
}

enum NavigationPromptKind: Equatable, Sendable {
    case far
    case near
    case rerouting
    case arrived
}

enum NavigationHapticKind: Equatable, Sendable {
    case far
    case near
    case offRoute
}

enum NavigationEvent: Equatable, Sendable {
    case stateChanged(NavigationState)
    case prompt(text: String, kind: NavigationPromptKind)
    case haptic(NavigationHapticKind)
    case progress(RouteProgress)
}

/// Pure Swift turn-by-turn state machine. Emits events; does not speak or vibrate itself.
final class NavigationEngine: @unchecked Sendable {
    typealias RerouteHandler = @Sendable (
        _ from: CLLocationCoordinate2D,
        _ to: CLLocationCoordinate2D
    ) async -> Result<PlannedRoute, RoutingError>

    private static let farMeters: Double = 150
    private static let nearMeters: Double = 30
    private static let speedScaleThresholdMPS: Double = 20 * 0.44704 // 20 mph
    private static let speedScaleFactor: Double = 1.5
    private static let offRouteMeters: Double = 30
    private static let offRouteSeconds: TimeInterval = 5
    private static let rerouteCooldown: TimeInterval = 10
    private static let arrivalMeters: Double = 20
    private static let maxMatchAccuracyMeters: Double = 25

    private(set) var state: NavigationState = .idle
    private(set) var progress: RouteProgress?
    private(set) var route: PlannedRoute?
    private(set) var maneuvers: [Maneuver] = []

    private var tracker: RouteProgressTracker?
    private var destination: CLLocationCoordinate2D?
    private var rerouteHandler: RerouteHandler?
    private var announcedFar: Set<UUID> = []
    private var announcedNear: Set<UUID> = []
    private var activeNextManeuverID: UUID?
    private var offRouteSince: Date?
    private var lastRerouteAt: Date?
    private var announcedArrival = false
    private var announcedRerouting = false
    private var rerouteTask: Task<Void, Never>?
    private var eventHandler: ((NavigationEvent) -> Void)?
    private var now: () -> Date = Date.init
    private let lock = NSLock()

    /// Rolling average speed (m/s) from recent on-route fixes for ETA.
    private(set) var rollingSpeedMPS: Double = 0
    private var speedSamples: [Double] = []

    func onEvent(_ handler: @escaping (NavigationEvent) -> Void) {
        eventHandler = handler
    }

    func start(
        route: PlannedRoute,
        maneuvers: [Maneuver]? = nil,
        rerouteHandler: RerouteHandler?,
        now: @escaping () -> Date = Date.init
    ) {
        stop()
        lock.lock()
        defer { lock.unlock() }
        self.now = now
        self.route = route
        self.destination = route.destination
        self.rerouteHandler = rerouteHandler
        let built = maneuvers ?? ManeuverBuilder.build(from: route)
        self.maneuvers = built
        self.tracker = RouteProgressTracker(coordinates: route.coordinates, maneuvers: built)
        self.announcedFar = []
        self.announcedNear = []
        self.activeNextManeuverID = nil
        self.offRouteSince = nil
        self.lastRerouteAt = nil
        self.announcedArrival = false
        self.announcedRerouting = false
        self.rollingSpeedMPS = 0
        self.speedSamples = []
        setState(.navigating)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        rerouteTask?.cancel()
        rerouteTask = nil
        tracker = nil
        route = nil
        maneuvers = []
        destination = nil
        rerouteHandler = nil
        progress = nil
        activeNextManeuverID = nil
        if state != .idle {
            setState(.idle)
        }
    }

    func update(location: CLLocation) {
        lock.lock()
        defer { lock.unlock() }
        updateLocked(location: location)
    }

    private func updateLocked(location: CLLocation) {
        guard state == .navigating || state == .offRoute || state == .rerouting || state == .arrived else {
            return
        }
        guard var tracker else { return }

        let updated = tracker.update(location: location)
        self.tracker = tracker
        progress = updated
        emit(.progress(updated))

        if location.speed >= 0 {
            recordSpeed(location.speed)
        }

        if state == .arrived {
            return
        }

        if state == .rerouting {
            return
        }

        // Arrival: require being near the end of the route so round trips don't
        // "arrive" at the origin while still outbound.
        if location.horizontalAccuracy >= 0,
           location.horizontalAccuracy <= Self.maxMatchAccuracyMeters,
           updated.didMatch,
           updated.remainingDistance <= Self.arrivalMeters {
            handleArrival()
            return
        }
        if let destination {
            let destLocation = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
            if location.horizontalAccuracy >= 0,
               location.horizontalAccuracy <= Self.maxMatchAccuracyMeters,
               updated.remainingDistance <= Self.arrivalMeters * 2,
               location.distance(from: destLocation) <= Self.arrivalMeters {
                handleArrival()
                return
            }
        }

        evaluateOffRoute(location: location, progress: updated)
        guard state == .navigating else { return }

        evaluatePrompts(location: location, progress: updated)
    }

    // MARK: - Prompts

    private func evaluatePrompts(location: CLLocation, progress: RouteProgress) {
        guard progress.didMatch, let next = progress.nextManeuver else { return }
        if next.type == .arrive {
            // Arrival is handled by proximity to destination, not the far/near schedule.
            return
        }

        let scale = Self.promptDistanceScale(speed: location.speed)
        let farThreshold = Self.farMeters * scale
        let nearThreshold = Self.nearMeters * scale
        let distance = progress.distanceToNextManeuver

        // When a maneuver newly becomes next and we're already inside the far window, skip far.
        if activeNextManeuverID != next.id {
            activeNextManeuverID = next.id
            if distance <= farThreshold {
                announcedFar.insert(next.id)
            }
        }

        if distance <= nearThreshold {
            announceNearIfNeeded(next)
        } else if distance <= farThreshold {
            announceFarIfNeeded(next, distanceMeters: distance)
        }
    }

    private func announceFarIfNeeded(_ maneuver: Maneuver, distanceMeters: Double) {
        guard !announcedFar.contains(maneuver.id) else { return }
        // Skip far if we already announced near (shouldn't happen) or if already inside near.
        guard !announcedNear.contains(maneuver.id) else { return }
        announcedFar.insert(maneuver.id)
        let text = Self.farPrompt(distanceMeters: distanceMeters, instruction: maneuver.instruction)
        emit(.prompt(text: text, kind: .far))
        emit(.haptic(.far))
    }

    private func announceNearIfNeeded(_ maneuver: Maneuver) {
        guard !announcedNear.contains(maneuver.id) else { return }
        // Skip far if we enter near without having announced far.
        announcedFar.insert(maneuver.id)
        announcedNear.insert(maneuver.id)
        let text = Self.nearPrompt(for: maneuver)
        emit(.prompt(text: text, kind: .near))
        emit(.haptic(.near))
    }

    static func promptDistanceScale(speed: CLLocationSpeed) -> Double {
        guard speed >= Self.speedScaleThresholdMPS else { return 1.0 }
        return Self.speedScaleFactor
    }

    static func farPrompt(distanceMeters: Double, instruction: String) -> String {
        let distance = DistanceFormat.spoken(distanceMeters)
        let clause = Self.lowercaseLeading(instruction)
        return "In \(distance), \(clause)"
    }

    static func nearPrompt(for maneuver: Maneuver) -> String {
        switch maneuver.type {
        case .depart:
            return maneuver.instruction
        case .continue:
            return "Continue"
        case .slightLeft:
            return "Bear left"
        case .slightRight:
            return "Bear right"
        case .left:
            return "Turn left"
        case .right:
            return "Turn right"
        case .sharpLeft:
            return "Sharp left"
        case .sharpRight:
            return "Sharp right"
        case .uTurn:
            if maneuver.instruction == ManeuverBuilder.roundTripTurnaroundInstruction {
                return ManeuverBuilder.roundTripTurnaroundInstruction
            }
            return "Make a U-turn"
        case .arrive:
            return "You have arrived"
        }
    }

    private static func lowercaseLeading(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).lowercased() + text.dropFirst()
    }

    // MARK: - Off-route / reroute

    private func evaluateOffRoute(location: CLLocation, progress: RouteProgress) {
        let accuracyOK = location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= Self.maxMatchAccuracyMeters
        let farFromRoute = progress.didMatch && progress.distanceFromRoute > Self.offRouteMeters

        if accuracyOK && farFromRoute {
            if offRouteSince == nil {
                offRouteSince = now()
            }
            if state == .navigating {
                setState(.offRoute)
                emit(.haptic(.offRoute))
            }
            if let since = offRouteSince,
               now().timeIntervalSince(since) >= Self.offRouteSeconds {
                triggerReroute(from: location.coordinate)
            }
        } else if accuracyOK && progress.didMatch && progress.distanceFromRoute <= Self.offRouteMeters {
            offRouteSince = nil
            if state == .offRoute {
                setState(.navigating)
            }
        }
        // Low-accuracy fixes neither start nor clear the off-route timer.
    }

    private func triggerReroute(from coordinate: CLLocationCoordinate2D) {
        guard let destination, let rerouteHandler else { return }
        if let last = lastRerouteAt, now().timeIntervalSince(last) < Self.rerouteCooldown {
            return
        }
        guard state != .rerouting else { return }

        lastRerouteAt = now()
        offRouteSince = nil
        setState(.rerouting)

        if !announcedRerouting {
            announcedRerouting = true
            emit(.prompt(text: "Rerouting", kind: .rerouting))
        }

        let handler = rerouteHandler
        rerouteTask?.cancel()
        rerouteTask = Task { [weak self] in
            let result = await handler(coordinate, destination)
            guard let self, !Task.isCancelled else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.handleRerouteResult(result)
        }
    }

    private func handleRerouteResult(_ result: Result<PlannedRoute, RoutingError>) {
        guard state == .rerouting else { return }
        switch result {
        case .success(let newRoute):
            route = newRoute
            destination = newRoute.destination
            let built = ManeuverBuilder.build(from: newRoute)
            maneuvers = built
            tracker = RouteProgressTracker(coordinates: newRoute.coordinates, maneuvers: built)
            announcedFar = []
            announcedNear = []
            activeNextManeuverID = nil
            announcedArrival = false
            announcedRerouting = false
            offRouteSince = nil
            setState(.navigating)
        case .failure:
            // Stay off-route; allow another attempt after cooldown.
            setState(.offRoute)
            announcedRerouting = false
        }
    }

    private func handleArrival() {
        guard !announcedArrival else { return }
        announcedArrival = true
        setState(.arrived)
        emit(.prompt(text: "You have arrived", kind: .arrived))
        emit(.haptic(.near))
    }

    // MARK: - Speed / ETA helpers

    private func recordSpeed(_ speed: Double) {
        guard speed > 0.5 else { return }
        speedSamples.append(speed)
        if speedSamples.count > 20 {
            speedSamples.removeFirst(speedSamples.count - 20)
        }
        rollingSpeedMPS = speedSamples.reduce(0, +) / Double(speedSamples.count)
    }

    private func setState(_ newState: NavigationState) {
        guard state != newState else { return }
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: NavigationEvent) {
        eventHandler?(event)
    }
}
