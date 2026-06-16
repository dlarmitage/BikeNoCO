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

    private let service = ArcGISService()

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
    }

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
