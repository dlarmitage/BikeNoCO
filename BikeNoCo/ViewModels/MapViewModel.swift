import Foundation
import MapKit
import Combine

enum MapCameraCommand: Equatable {
    case zoomIn
    case zoomOut
    case fortCollins
}

enum MapStyle: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case muted = "Muted"
    case satellite = "Satellite"
    case hybrid = "Hybrid"

    var id: String { rawValue }

    var mapType: MKMapType {
        switch self {
        case .standard: return .standard
        case .muted:    return .mutedStandard
        case .satellite: return .satellite
        case .hybrid:   return .hybrid
        }
    }

    var icon: String {
        switch self {
        case .standard:  return "map"
        case .muted:     return "map.fill"
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
    @Published var routingError: RoutingError?
    @Published var isRouting = false
    /// True only when routing is unavailable because there is no usable cached/built graph yet.
    @Published var isPreparingRoutes = false

    private let service = ArcGISService()
    private var networkGraph: BikeNetworkGraph?
    private var cachedGraphKey: String?
    private var routeGeneration = 0

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
    func toggleLocationTracking() {
        if trackingMode == .follow {
            trackingMode = .none
            return
        }
        if let coordinate = userCoordinate, Self.isInNorthernColorado(coordinate) {
            trackingMode = .follow
        } else {
            trackingMode = .none
            cameraCommand = .fortCollins
        }
    }

    func planRoute(to destination: CLLocationCoordinate2D) {
        routeDestination = destination
        routingError = nil
        plannedRoute = nil

        guard let graph = networkGraph else {
            routingError = .noPath(hint: "Bike network is still loading. Try again in a moment.")
            return
        }

        let origin = routingOrigin
        isRouting = true
        routeGeneration += 1
        let generation = routeGeneration
        let profile = RoutingProfile.default

        Task.detached(priority: .userInitiated) {
            let result = RouteFinder.route(
                from: origin,
                to: destination,
                graph: graph,
                profile: profile
            )
            await MainActor.run {
                guard generation == self.routeGeneration else { return }
                self.isRouting = false
                switch result {
                case .success(let route):
                    self.plannedRoute = route
                    self.routingError = nil
                case .failure(let error):
                    self.plannedRoute = nil
                    self.routingError = error
                }
            }
        }
    }

    func clearPlannedRoute() {
        routeGeneration += 1
        plannedRoute = nil
        routeDestination = nil
        routingError = nil
        isRouting = false
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
