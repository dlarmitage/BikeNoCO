import Foundation
import MapKit
import Combine

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
    @Published var trackingMode: MKUserTrackingMode = .follow
    @Published var focusRouteID: UUID?
    @Published var activeRouteID: UUID?

    @Published var userCoordinate: CLLocationCoordinate2D?
    @Published var routeDestination: CLLocationCoordinate2D?
    @Published var plannedRoute: PlannedRoute?
    @Published var routingError: RoutingError?
    @Published var isRouting = false

    private let service = ArcGISService()
    private var networkGraph: BikeNetworkGraph?
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
        isLoading = true
        loadProgress = 0
        errorMessage = nil

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
            Task.detached(priority: .utility) {
                let buildStart = CFAbsoluteTimeGetCurrent()
                let graph = BikeNetworkGraphBuilder.build(from: loaded)
                let buildElapsed = CFAbsoluteTimeGetCurrent() - buildStart
                await MainActor.run {
                    self.networkGraph = graph
                }
                #if DEBUG
                Self.debugPrintConnectivity(graph: graph, routeCount: loaded.count, buildElapsed: buildElapsed)
                #endif
            }
        }
    }

    func planRoute(to destination: CLLocationCoordinate2D) {
        routeDestination = destination
        routingError = nil
        plannedRoute = nil

        guard let origin = userCoordinate else {
            routingError = .originTooFar
            return
        }
        guard let graph = networkGraph else {
            routingError = .noPath(hint: "Bike network is still loading. Try again in a moment.")
            return
        }

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
        graph: BikeNetworkGraph,
        routeCount: Int,
        buildElapsed: CFAbsoluteTime
    ) {
        NSLog("[BikeNoCo Graph] built from %d routes in %.3fs — computing connectivity…", routeCount, buildElapsed)
        let reportStart = CFAbsoluteTimeGetCurrent()
        let report = ConnectivityReport.make(from: graph)
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
