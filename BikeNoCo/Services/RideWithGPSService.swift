import Foundation
import CoreLocation

struct RideWithGPSService {
    private static let recommendedRouteIDs = [29129213, 29129105, 29147414, 29129397]

    func fetchRoutes() async -> [BikeRoute] {
        await withTaskGroup(of: BikeRoute?.self) { group in
            for id in Self.recommendedRouteIDs {
                group.addTask { await fetchRoute(id: id) }
            }
            var routes: [BikeRoute] = []
            for await route in group {
                if let route { routes.append(route) }
            }
            return routes
        }
    }

    private func fetchRoute(id: Int) async -> BikeRoute? {
        guard let url = URL(string: "https://ridewithgps.com/routes/\(id).json") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            print("BikeNoCo: RideWithGPS fetch failed for route \(id)")
            return nil
        }
        guard let json = try? JSONDecoder().decode(RWGPSRoute.self, from: data) else {
            print("BikeNoCo: RideWithGPS decode failed for route \(id)")
            return nil
        }

        let coords = json.trackPoints.map {
            CLLocationCoordinate2D(latitude: $0.y, longitude: $0.x)
        }
        guard !coords.isEmpty else { return nil }

        let displayName = json.name
            .replacingOccurrences(of: "Great Rides Fort Collins - ", with: "")

        return BikeRoute(
            id: UUID(),
            objectId: json.id,
            streetName: displayName,
            facilityType: .recommendedRide,
            lts: nil,
            mapSymbolClass: nil,
            bikewayName: nil,
            speedLimit: nil,
            paths: [coords],
            routeDistance: json.distance,
            elevationGain: json.elevationGain,
            routeDescription: json.description
        )
    }
}

private struct RWGPSRoute: Decodable {
    let id: Int
    let name: String
    let distance: Double
    let elevationGain: Double
    let description: String?
    let trackPoints: [TrackPoint]

    enum CodingKeys: String, CodingKey {
        case id, name, distance, description
        case elevationGain = "elevation_gain"
        case trackPoints = "track_points"
    }

    struct TrackPoint: Decodable {
        let x: Double // longitude
        let y: Double // latitude
    }
}
