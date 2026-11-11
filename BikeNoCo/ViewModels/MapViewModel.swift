import Foundation
import MapKit
import Combine

enum MapCameraCommand: Equatable {
    case zoomIn
    case zoomOut
    case fortCollins
    /// Keep center/zoom; set heading and pitch to north-up / flat.
    case northUp
}

enum MapStyle: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case satellite = "Satellite"
    case hybrid = "Hybrid"

    var id: String { rawValue }

    var mapType: MKMapType {
        switch self {
        case .standard: return .standard
        case .satellite: return .satellite
        case .hybrid:   return .hybrid
        }
    }

    var icon: String {
        switch self {
        case .standard:  return "map"
        case .satellite: return "globe.americas.fill"
        case .hybrid:    return "square.2.layers.3d.fill"
        }
    }
}

@MainActor
final class MapViewModel: ObservableObject {
    @Published var routes: [BikeRoute] = []
    @Published var visibleTypes: Set<FacilityType> = Set(FacilityType.allCases)
    @Published var isLoading = false
    @Published var loadProgress: Double = 0
    @Published var errorMessage: String?
    @Published var mapStyle: MapStyle = .hybrid
    @Published var trackingMode: MKUserTrackingMode = .none
    @Published var focusRouteID: UUID?
    @Published var activeRouteID: UUID?
    /// One-shot camera commands consumed by `BikeMapView` (zoom / Fort Collins recenter).
    @Published var cameraCommand: MapCameraCommand?

    @Published var userCoordinate: CLLocationCoordinate2D?
    @Published var routeDestination: CLLocationCoordinate2D?
    @Published var plannedRoute: PlannedRoute?
    @Published var tripShape: TripShape = .oneWay
    @Published var routingError: RoutingError?
    @Published var isRouting = false
    /// True only when routing is unavailable because there is no usable cached/built graph yet.
    @Published var isPreparingRoutes = false

    // Distance-loop planner (task 06b)
    @Published var loopCandidates: [LoopCandidate] = []
    @Published var isSearchingLoops = false
    @Published var loopSearchError: String?
    @Published var lastLoopSearchSeconds: Double?
    @Published var lastLoopTimeToFirstSeconds: Double?
    @Published var loopTargetMiles: Double = 10
    @Published var loopMaxLTS: Int? = nil
    @Published var loopPreferTrails = false
    /// When true, loop search starts from a long-pressed map pin (`routeDestination`).
    @Published var loopStartUsesPin = false
    /// True when `plannedRoute` came from the distance-loop planner (hide via-shape picker).
    @Published private(set) var plannedRouteIsDistanceLoop = false
    /// Cancellation flag for the in-flight distance-loop search.
    private var loopSearchToken = LoopSearchToken()

    private let service = ArcGISService()
    private var networkGraph: BikeNetworkGraph?
    private var cachedGraphKey: String?
    private var routeGeneration = 0
    private var loopSearchGeneration = 0
    /// One-way result before round-trip doubling; toggle rebuilds `plannedRoute` from this.
    private var oneWayPlannedRoute: PlannedRoute?

    /// Graph used for planning and live reroutes. Nil until cache/build completes.
    var routingGraph: BikeNetworkGraph? { networkGraph }

    var filteredRoutes: [BikeRoute] {
        routes.filter { visibleTypes.contains($0.facilityType) && $0.facilityType != .recommendedRide }
    }

    var recommendedRoutes: [BikeRoute] {
        routes.filter { $0.facilityType == .recommendedRide }
    }

    var activeRoute: BikeRoute? {
        guard let id = activeRouteID else { return nil }
        return routes.first { $0.id == id }
    }

    func loadRoutes() async {
        guard routes.isEmpty else { return }

        // Serve a cached graph immediately if present so routing is available during fetch.
        let cacheLoadStart = CFAbsoluteTimeGetCurrent()
        if let cached = try? GraphCache.load() {
            networkGraph = cached.graph
            cachedGraphKey = cached.key
            let cacheElapsed = CFAbsoluteTimeGetCurrent() - cacheLoadStart
            NSLog("[BikeNoCo Graph] loaded cached graph in %.3fs (key prefix %@…)", cacheElapsed, String(cached.key.prefix(8)))
        } else {
            isPreparingRoutes = true
        }

        isLoading = true
        loadProgress = 0
        errorMessage = nil

        // Decode bundled OSM while ArcGIS fetch runs so cold rebuild avoids serial decode cost.
        let osmPreload = Task.detached(priority: .utility) { () -> Result<OSMConnectorFile, Error> in
            Result { try OSMConnectorLoader.loadBundled() }
        }

        do {
            routes = try await service.fetchAllRoutes { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.loadProgress = progress
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        loadProgress = 1

        if !routes.isEmpty {
            let loaded = routes
            let existingKey = cachedGraphKey
            Task.detached(priority: .utility) {
                await Self.rebuildGraphIfNeeded(
                    routes: loaded,
                    existingKey: existingKey,
                    osmPreload: osmPreload,
                    viewModel: self
                )
            }
        } else if networkGraph == nil {
            isPreparingRoutes = false
        }
    }

    private nonisolated static func rebuildGraphIfNeeded(
        routes: [BikeRoute],
        existingKey: String?,
        osmPreload: Task<Result<OSMConnectorFile, Error>, Never>,
        viewModel: MapViewModel
    ) async {
        let decodeStart = CFAbsoluteTimeGetCurrent()
        let osmFile: OSMConnectorFile
        do {
            osmFile = try await osmPreload.value.get()
        } catch {
            NSLog("[BikeNoCo Graph] OSM connectors unavailable: %@", error.localizedDescription)
            await MainActor.run {
                if viewModel.networkGraph == nil {
                    viewModel.isPreparingRoutes = false
                }
            }
            return
        }
        let decodeElapsed = CFAbsoluteTimeGetCurrent() - decodeStart
        let key = GraphCache.makeKey(routes: routes, osmTimestamp: osmFile.meta.osmTimestamp)

        if let existingKey, existingKey == key {
            NSLog("[BikeNoCo Graph] cache key unchanged — skipping rebuild")
            await MainActor.run {
                viewModel.isPreparingRoutes = false
            }
            return
        }

        await MainActor.run {
            if viewModel.networkGraph == nil {
                viewModel.isPreparingRoutes = true
            }
        }

        let buildStart = CFAbsoluteTimeGetCurrent()
        var result = BikeNetworkGraphBuilder.build(from: routes, connectors: osmFile.edges)
        result.timing.osmDecode = decodeElapsed
        let buildElapsed = CFAbsoluteTimeGetCurrent() - buildStart

        let writeStart = CFAbsoluteTimeGetCurrent()
        do {
            try GraphCache.save(graph: result.graph, key: key, osmTimestamp: osmFile.meta.osmTimestamp)
            result.timing.cacheWrite = CFAbsoluteTimeGetCurrent() - writeStart
        } catch {
            NSLog("[BikeNoCo Graph] cache write failed: %@", error.localizedDescription)
        }

        await MainActor.run {
            viewModel.networkGraph = result.graph
            viewModel.cachedGraphKey = key
            viewModel.isPreparingRoutes = false
        }

        #if DEBUG
        Self.debugPrintConnectivity(result: result, routeCount: routes.count, buildElapsed: buildElapsed)
        #endif
    }

    /// Approximate Northern Colorado coverage (Fort Collins / Loveland / Greeley).
    static func isInNorthernColorado(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (40.25...40.85).contains(coordinate.latitude)
            && (-105.35 ... -104.55).contains(coordinate.longitude)
    }

    /// Used when GPS is missing or still the Simulator's Bay Area default.
    static let fortCollinsOrigin = CLLocationCoordinate2D(latitude: 40.5853, longitude: -105.0844)

    /// Prefer a live NoCo fix; otherwise fall back so desk testing still works.
    var routingOrigin: CLLocationCoordinate2D {
        if let coordinate = userCoordinate, Self.isInNorthernColorado(coordinate) {
            return coordinate
        }
        return Self.fortCollinsOrigin
    }

    /// Toggle follow-me when the user is in NoCo; otherwise recenter on Fort Collins.
    /// Avoids Simulator's default Bay Area location yanking the map to San Francisco.
    /// Re-engaging follow always restores north-up (escape hatch after heading-up navigation).
    func toggleLocationTracking() {
        if trackingMode == .follow {
            trackingMode = .none
            return
        }
        if trackingMode == .followWithHeading {
            // Step out of heading-up into north-up follow.
            trackingMode = .follow
            cameraCommand = .northUp
            return
        }
        if let coordinate = userCoordinate, Self.isInNorthernColorado(coordinate) {
            trackingMode = .follow
            cameraCommand = .northUp
        } else {
            trackingMode = .none
            cameraCommand = .fortCollins
        }
    }

    func planRoute(to destination: CLLocationCoordinate2D) {
        routeDestination = destination
        routingError = nil
        plannedRoute = nil
        oneWayPlannedRoute = nil

        guard let graph = networkGraph else {
            routingError = .noPath(hint: "Bike network is still loading. Try again in a moment.")
            return
        }

        let origin = routingOrigin
        isRouting = true
        routeGeneration += 1
        let generation = routeGeneration
        let profile = RoutingProfile.default
        let shape = tripShape

        Task.detached(priority: .userInitiated) {
            let result = Self.buildTrip(
                origin: origin,
                destination: destination,
                graph: graph,
                profile: profile,
                shape: shape
            )
            await MainActor.run {
                guard generation == self.routeGeneration else { return }
                self.isRouting = false
                switch result {
                case .success(let built):
                    self.oneWayPlannedRoute = built.oneWay
                    self.plannedRoute = built.display
                    self.plannedRouteIsDistanceLoop = false
                    self.routingError = nil
                case .failure(let error):
                    self.oneWayPlannedRoute = nil
                    self.plannedRoute = nil
                    self.plannedRouteIsDistanceLoop = false
                    self.routingError = error
                }
            }
        }
    }

    func setTripShape(_ shape: TripShape) {
        tripShape = shape
        guard !plannedRouteIsDistanceLoop else { return }
        guard let oneWay = oneWayPlannedRoute else { return }
        guard let graph = networkGraph else {
            plannedRoute = applyShape(shape, to: oneWay, graph: nil)
            return
        }
        // Loop needs a fresh return-leg search; out & back / one way are local transforms.
        if shape == .loop {
            let destination = routeDestination ?? oneWay.destination
            let origin = oneWay.origin
            isRouting = true
            routeGeneration += 1
            let generation = routeGeneration
            let profile = RoutingProfile.default
            Task.detached(priority: .userInitiated) {
                let result = Self.buildTrip(
                    origin: origin,
                    destination: destination,
                    graph: graph,
                    profile: profile,
                    shape: .loop,
                    existingOutbound: oneWay
                )
                await MainActor.run {
                    guard generation == self.routeGeneration else { return }
                    self.isRouting = false
                    switch result {
                    case .success(let built):
                        self.oneWayPlannedRoute = built.oneWay
                        self.plannedRoute = built.display
                        self.plannedRouteIsDistanceLoop = false
                        self.routingError = nil
                    case .failure(let error):
                        self.routingError = error
                    }
                }
            }
            return
        }
        plannedRoute = applyShape(shape, to: oneWay, graph: graph)
        plannedRouteIsDistanceLoop = false
    }

    private func applyShape(
        _ shape: TripShape,
        to oneWay: PlannedRoute,
        graph: BikeNetworkGraph?
    ) -> PlannedRoute {
        switch shape {
        case .oneWay:
            return oneWay
        case .outAndBack:
            return oneWay.asOutAndBack()
        case .loop:
            // Fallback if called without async rebuild — prefer a real loop when graph is present.
            if let graph {
                if case .success(let looped) = RouteFinder.loop(outbound: oneWay, graph: graph) {
                    return looped
                }
            }
            return oneWay.asOutAndBack()
        }
    }

    private struct BuiltTrip: Sendable {
        var oneWay: PlannedRoute
        var display: PlannedRoute
    }

    private nonisolated static func buildTrip(
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D,
        graph: BikeNetworkGraph,
        profile: RoutingProfile,
        shape: TripShape,
        existingOutbound: PlannedRoute? = nil
    ) -> Result<BuiltTrip, RoutingError> {
        let outboundResult: Result<PlannedRoute, RoutingError>
        if let existingOutbound {
            outboundResult = .success(existingOutbound)
        } else {
            outboundResult = RouteFinder.route(
                from: origin,
                to: destination,
                graph: graph,
                profile: profile
            )
        }
        switch outboundResult {
        case .failure(let error):
            return .failure(error)
        case .success(let oneWay):
            switch shape {
            case .oneWay:
                return .success(BuiltTrip(oneWay: oneWay, display: oneWay))
            case .outAndBack:
                return .success(BuiltTrip(oneWay: oneWay, display: oneWay.asOutAndBack()))
            case .loop:
                switch RouteFinder.loop(outbound: oneWay, graph: graph, profile: profile) {
                case .success(let looped):
                    return .success(BuiltTrip(oneWay: oneWay, display: looped))
                case .failure(let error):
                    return .failure(error)
                }
            }
        }
    }

    /// Loads a saved route's waypoints onto the map via `RouteFinder.routeThrough`.
    func loadSavedRoute(waypoints: [CLLocationCoordinate2D], name: String? = nil) {
        routingError = nil
        plannedRoute = nil
        oneWayPlannedRoute = nil
        plannedRouteIsDistanceLoop = false
        tripShape = .oneWay

        guard waypoints.count >= 2 else {
            routingError = .noPath(hint: "That saved route has no waypoints.")
            return
        }
        guard let graph = networkGraph else {
            routingError = .noPath(hint: "Bike network is still loading. Try again in a moment.")
            return
        }

        routeDestination = waypoints.last
        isRouting = true
        routeGeneration += 1
        let generation = routeGeneration
        let profile = RoutingProfile.default

        Task.detached(priority: .userInitiated) {
            let result = RouteFinder.routeThrough(
                waypoints: waypoints,
                graph: graph,
                profile: profile
            )
            await MainActor.run {
                guard generation == self.routeGeneration else { return }
                self.isRouting = false
                switch result {
                case .success(let planned):
                    self.oneWayPlannedRoute = planned
                    self.plannedRoute = planned
                    self.routingError = nil
                    if let name, !name.isEmpty {
                        NSLog("[BikeNoCo] Loaded saved route \"%@\" (%.1f mi)", name, planned.totalDistanceMeters / 1609.344)
                    }
                case .failure(let error):
                    self.oneWayPlannedRoute = nil
                    self.plannedRoute = nil
                    self.routingError = error
                }
            }
        }
    }

    func clearPlannedRoute() {
        routeGeneration += 1
        plannedRoute = nil
        oneWayPlannedRoute = nil
        routeDestination = nil
        routingError = nil
        isRouting = false
        plannedRouteIsDistanceLoop = false
    }

    /// Origin for distance-loop search: optional map pin, else live NoCo fix, else Fort Collins.
    var loopSearchOrigin: CLLocationCoordinate2D {
        if loopStartUsesPin, let pin = routeDestination {
            return pin
        }
        return routingOrigin
    }

    var loopSearchUsesPin: Bool { loopStartUsesPin && routeDestination != nil }

    func searchLoops() {
        guard let graph = networkGraph else {
            loopSearchError = "Bike network is still loading. Try again in a moment."
            isSearchingLoops = false
            return
        }
        if loopStartUsesPin && routeDestination == nil {
            loopSearchError = "Long-press the map to drop a start pin, then try again."
            isSearchingLoops = false
            return
        }

        let constraints = currentLoopConstraints()
        let token = LoopSearchToken()
        loopSearchToken.cancel()
        loopSearchToken = token
        isSearchingLoops = true
        loopSearchError = nil
        loopCandidates = []
        lastLoopSearchSeconds = nil
        lastLoopTimeToFirstSeconds = nil
        loopSearchGeneration += 1
        let generation = loopSearchGeneration
        let profile = RoutingProfile.default
        NSLog(
            "[BikeNoCo Loop] search start — %.0f mi, maxLTS=%@, trails=%d, pin=%d",
            loopTargetMiles,
            loopMaxLTS.map(String.init) ?? "any",
            loopPreferTrails ? 1 : 0,
            loopSearchUsesPin ? 1 : 0
        )

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DistanceLoopPlanner.search(
                    constraints: constraints,
                    graph: graph,
                    profile: profile,
                    isCancelled: { token.isCancelled },
                    onShortlistChanged: { shortlist in
                        Task { @MainActor in
                            guard generation == self.loopSearchGeneration else { return }
                            self.loopCandidates = shortlist
                        }
                    }
                )
            }.value

            guard generation == loopSearchGeneration else { return }
            isSearchingLoops = false
            lastLoopSearchSeconds = result.elapsedSeconds
            lastLoopTimeToFirstSeconds = result.timeToFirstResultSeconds
            loopCandidates = result.candidates
            NSLog(
                "[BikeNoCo Loop] search done — %d candidates in %.2fs",
                result.candidates.count,
                result.elapsedSeconds
            )
            if result.candidates.isEmpty && !token.isCancelled {
                loopSearchError =
                    "Couldn't find loops near that distance. Try a different length, allow busier streets, or turn off Prefer trails."
            }
        }
    }

    func refineLoopsShorter() {
        loopTargetMiles = max(3, loopTargetMiles * 0.8)
        searchLoops()
    }

    func refineLoopsLonger() {
        loopTargetMiles = min(40, loopTargetMiles * 1.2)
        searchLoops()
    }

    func refineLoopsMoreTrail() {
        loopPreferTrails = true
        searchLoops()
    }

    func selectLoopCandidate(_ candidate: LoopCandidate) {
        plannedRoute = candidate.route
        oneWayPlannedRoute = nil
        tripShape = .loop
        plannedRouteIsDistanceLoop = true
        routeDestination = nil
        routingError = nil
    }

    func cancelLoopSearch() {
        loopSearchToken.cancel()
        loopSearchGeneration += 1
        isSearchingLoops = false
    }

    private func currentLoopConstraints() -> LoopSearchConstraints {
        LoopSearchConstraints(
            origin: loopSearchOrigin,
            targetDistanceMeters: loopTargetMiles * 1609.344,
            tolerance: 0.10,
            maxLTS: loopMaxLTS,
            preferTrails: loopPreferTrails,
            // Prefer-trails raises scoring weight; hard minTrailShare stays optional/strict.
            minTrailShare: nil,
            elevationPreference: nil
        )
    }

    #if DEBUG
    nonisolated private static func debugPrintConnectivity(
        result: BikeNetworkGraphBuildResult,
        routeCount: Int,
        buildElapsed: CFAbsoluteTime
    ) {
        NSLog(
            "[BikeNoCo Graph] built from %d routes + %d OSM edges (%d kept) in %.3fs — computing connectivity…",
            routeCount,
            result.osmEdgesLoaded,
            result.osmEdgesKept,
            buildElapsed
        )
        NSLog(
            "[BikeNoCo Graph] crossings considered: %d  joined via OSM: %d  attachment edges: %d",
            result.crossingsConsidered,
            result.crossingsJoined,
            result.attachmentEdgeCount
        )
        NSLog(
            "[BikeNoCo Graph] after prune: components=%d largest=%.1f%%",
            result.componentsAfterPrune,
            result.largestComponentShareAfterPrune * 100
        )
        NSLog("%@", result.timing.summary)
        let reportStart = CFAbsoluteTimeGetCurrent()
        let report = ConnectivityReport.make(from: result.graph)
        let reportElapsed = CFAbsoluteTimeGetCurrent() - reportStart
        NSLog("%@", report.summary)
        NSLog("[BikeNoCo Graph] build time: %.3fs  report time: %.3fs", buildElapsed, reportElapsed)
        NSLog("[BikeNoCo Graph] Top 20 gap candidates by distance:")
        let top = report.gapCandidates.prefix(20)
        if top.isEmpty {
            NSLog("[BikeNoCo Graph]   (none)")
        }
        for (index, gap) in top.enumerated() {
            NSLog(
                "[BikeNoCo Graph]   %2d. %.1f m  (%.5f, %.5f) <-> (%.5f, %.5f)",
                index + 1,
                gap.distanceMeters,
                gap.danglingCoordinate.latitude,
                gap.danglingCoordinate.longitude,
                gap.otherCoordinate.latitude,
                gap.otherCoordinate.longitude
            )
        }
    }
    #endif

    func toggleType(_ type: FacilityType) {
        if visibleTypes.contains(type) {
            visibleTypes.remove(type)
        } else {
            visibleTypes.insert(type)
        }
    }

    func showAll() {
        visibleTypes = Set(FacilityType.allCases)
    }

    func hideAll() {
        visibleTypes = []
    }
}

/// Shared cancel flag for a background distance-loop search.
private final class LoopSearchToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
