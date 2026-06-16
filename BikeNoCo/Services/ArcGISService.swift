import Foundation
import CoreLocation

enum ArcGISError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError(let e): return "Data error: \(e.localizedDescription)"
        }
    }
}

struct ArcGISService {
    // Fort Collins
    private static let bikeFacilitiesURL = "https://services1.arcgis.com/dLpFH5mwVvxSN4OE/arcgis/rest/services/BikeFacilities/FeatureServer/0"
    private static let trailsURL         = "https://services1.arcgis.com/dLpFH5mwVvxSN4OE/arcgis/rest/services/Trails/FeatureServer/0"
    private static let bikeFields  = "OBJECTID,BIKEINFRA_TYPE,STRNAME,LTS,MAPSYMBOLCLASS,BIKEWAYNAME,SPEEDLIMIT"
    private static let trailFields = "OBJECTID,NAME,CATEGORY,CONSTRUCTIONTYPE,SURFACE,BIKEUSE"
    private static let pageSize    = 2000

    // Loveland
    private static let lvBikewaysURL = "https://pwmaps.cityofloveland.org/arcgis/rest/services/BicycleTransportation/Bikeways/MapServer"
    private static let lvLayersURL   = "https://mapserv.cityofloveland.org/arcgis/rest/services/layers"

    func fetchAllRoutes(onProgress: @escaping (Double) -> Void) async throws -> [BikeRoute] {
        defer { onProgress(1.0) }

        // All sources start concurrently; Loveland, FC trails, and RideWithGPS are best-effort.
        async let bikeRoutes  = fetchBikeFacilities()
        async let loveland    = fetchLovelandRoutes()
        async let recommended = RideWithGPSService().fetchRoutes()

        var trails: [BikeRoute] = []
        do {
            trails = try await fetchTrails()
        } catch {
            print("BikeNoCo: FC trails skipped — \(error.localizedDescription)")
        }

        let bikes = try await bikeRoutes
        let lov   = await loveland
        let rides = await recommended
        // Recommended rides last so they render on top of infrastructure overlays
        return bikes + trails + lov + rides
    }

    // MARK: - Bike Facilities

    private func fetchBikeFacilities() async throws -> [BikeRoute] {
        let total = try await fetchCount(from: Self.bikeFacilitiesURL)
        let pages = Int(ceil(Double(total) / Double(Self.pageSize)))
        var routes: [BikeRoute] = []
        for page in 0..<pages {
            let features = try await fetchPage(
                from: Self.bikeFacilitiesURL,
                fields: Self.bikeFields,
                where: "1=1",
                offset: page * Self.pageSize
            )
            routes.append(contentsOf: features.compactMap { parseBikeFeature($0) })
        }
        return routes
    }

    private func parseBikeFeature(_ feature: GeoJSONFeature) -> BikeRoute? {
        guard let geometry = feature.geometry, let props = feature.properties else { return nil }
        let paths = geometry.coordinates.paths
        guard !paths.isEmpty else { return nil }
        return BikeRoute(
            id: UUID(),
            objectId: props.objectId ?? 0,
            streetName: (props.strName ?? "").capitalized,
            facilityType: FacilityType.from(props.bikeInfraType),
            lts: props.lts,
            mapSymbolClass: props.mapSymbolClass,
            bikewayName: props.bikewayName.flatMap { $0.isEmpty ? nil : $0 },
            speedLimit: props.speedLimit,
            paths: paths
        )
    }

    // MARK: - Trails

    private func fetchTrails() async throws -> [BikeRoute] {
        var components = URLComponents(string: "\(Self.trailsURL)/query")!
        components.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "outFields", value: Self.trailFields),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "f", value: "geojson"),
            URLQueryItem(name: "resultRecordCount", value: "2000")
        ]
        guard let url = components.url else { throw ArcGISError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        do {
            let collection = try JSONDecoder().decode(GeoJSONTrailFeatureCollection.self, from: data)
            // Filter client-side: include trails where biking is permitted OR where
            // bikeUse couldn't be determined (unknown field type → still show the trail)
            return collection.features
                .filter { f in
                    guard let bikeUse = f.properties?.bikeUse else { return true }
                    return bikeUse.lowercased() == "yes"
                }
                .compactMap { parseTrailFeature($0) }
        } catch {
            if let preview = String(data: data.prefix(300), encoding: .utf8) {
                print("BikeNoCo: trails decode error — response was: \(preview)")
            }
            throw error
        }
    }

    private func parseTrailFeature(_ feature: GeoJSONTrailFeature) -> BikeRoute? {
        guard let geometry = feature.geometry, let props = feature.properties else { return nil }
        let paths = geometry.coordinates.paths
        guard !paths.isEmpty else { return nil }

        let isPaved = (props.constructionType ?? "").lowercased().contains("paved")
            || (props.surface ?? "").lowercased() == "hard"
        let facilityType: FacilityType = isPaved ? .pavedTrail : .naturalTrail

        let name = (props.name ?? "")
            .capitalized
            .replacingOccurrences(of: "None-\\d+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return BikeRoute(
            id: UUID(),
            objectId: props.objectId ?? 0,
            streetName: name,
            facilityType: facilityType,
            lts: nil,
            mapSymbolClass: props.category,
            bikewayName: nil,
            speedLimit: nil,
            paths: paths
        )
    }

    // MARK: - Loveland

    /// Fetches all five Loveland layers concurrently; individual failures are silently skipped.
    private func fetchLovelandRoutes() async -> [BikeRoute] {
        async let a = fetchLovelandBikeway(layer: 1, facilityType: .bufferedBikeLane)
        async let b = fetchLovelandBikeway(layer: 3, facilityType: .bikeLane)
        async let c = fetchLovelandBikeRoutes()
        async let d = fetchLovelandRecTrail()
        async let e = fetchLovelandParkTrails()

        var routes: [BikeRoute] = []
        routes += (try? await a) ?? []
        routes += (try? await b) ?? []
        routes += (try? await c) ?? []
        routes += (try? await d) ?? []
        routes += (try? await e) ?? []
        return routes
    }

    private func fetchLovelandBikeway(layer: Int, facilityType: FacilityType) async throws -> [BikeRoute] {
        let data = try await fetchRaw(
            from: "\(Self.lvBikewaysURL)/\(layer)/query",
            fields: "OBJECTID,FULLSTNAME", where: "1=1"
        )
        return try JSONDecoder().decode(GFCollection<LovelandBikewayProperties>.self, from: data)
            .features.compactMap { f in
                guard let paths = f.geometry.map({ $0.coordinates.paths }), !paths.isEmpty else { return nil }
                return BikeRoute(
                    id: UUID(), objectId: f.properties?.objectId ?? 0,
                    streetName: (f.properties?.fullStName ?? "").capitalized,
                    facilityType: facilityType,
                    lts: nil, mapSymbolClass: nil, bikewayName: nil, speedLimit: nil, paths: paths
                )
            }
    }

    private func fetchLovelandBikeRoutes() async throws -> [BikeRoute] {
        let data = try await fetchRaw(
            from: "\(Self.lvBikewaysURL)/2/query",
            fields: "OBJECTID,FULLSTNAME,BIKERTELT,BIKERTERT",
            where: "BIKERTELT='Yes' OR BIKERTERT='Yes'"
        )
        return try JSONDecoder().decode(GFCollection<LovelandBikeRouteProperties>.self, from: data)
            .features.compactMap { f in
                guard let paths = f.geometry.map({ $0.coordinates.paths }), !paths.isEmpty else { return nil }
                return BikeRoute(
                    id: UUID(), objectId: f.properties?.objectId ?? 0,
                    streetName: (f.properties?.fullStName ?? "").capitalized,
                    facilityType: .sharrow,
                    lts: nil, mapSymbolClass: nil, bikewayName: nil, speedLimit: nil, paths: paths
                )
            }
    }

    private func fetchLovelandRecTrail() async throws -> [BikeRoute] {
        let data = try await fetchRaw(
            from: "\(Self.lvLayersURL)/RecTrail/MapServer/0/query",
            fields: "OBJECTID,TYPE,ALTTRAILNAME,SURFACETYPE", where: "1=1"
        )
        return try JSONDecoder().decode(GFCollection<LovelandRecTrailProperties>.self, from: data)
            .features.compactMap { f in
                guard let paths = f.geometry.map({ $0.coordinates.paths }), !paths.isEmpty else { return nil }
                let p = f.properties
                let name = [p?.altTrailName, p?.typeName]
                    .compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }.first ?? ""
                return BikeRoute(
                    id: UUID(), objectId: p?.objectId ?? 0,
                    streetName: name.capitalized,
                    facilityType: .pavedTrail,
                    lts: nil, mapSymbolClass: nil, bikewayName: nil, speedLimit: nil, paths: paths
                )
            }
    }

    private func fetchLovelandParkTrails() async throws -> [BikeRoute] {
        let data = try await fetchRaw(
            from: "\(Self.lvLayersURL)/NaturalAreaParkTrails/MapServer/0/query",
            fields: "OBJECTID,NAME,SURFTYPE,MAIN_TYPE,ROADCYCLE,MTBCYCLE",
            where: "ROADCYCLE='Yes' OR MTBCYCLE='Yes'"
        )
        return try JSONDecoder().decode(GFCollection<LovelandParkTrailProperties>.self, from: data)
            .features.compactMap { f in
                guard let paths = f.geometry.map({ $0.coordinates.paths }), !paths.isEmpty else { return nil }
                let p = f.properties
                let isPaved = (p?.surfType ?? "").lowercased() == "concrete"
                    || (p?.mainType ?? "").lowercased().contains("paved")
                return BikeRoute(
                    id: UUID(), objectId: p?.objectId ?? 0,
                    streetName: (p?.name ?? "").capitalized,
                    facilityType: isPaved ? .pavedTrail : .naturalTrail,
                    lts: nil, mapSymbolClass: nil, bikewayName: nil, speedLimit: nil, paths: paths
                )
            }
    }

    private func fetchRaw(from urlString: String, fields: String, where whereClause: String) async throws -> Data {
        var components = URLComponents(string: urlString)!
        components.queryItems = [
            URLQueryItem(name: "where",             value: whereClause),
            URLQueryItem(name: "outFields",         value: fields),
            URLQueryItem(name: "returnGeometry",    value: "true"),
            URLQueryItem(name: "outSR",             value: "4326"),
            URLQueryItem(name: "f",                 value: "geojson"),
            URLQueryItem(name: "resultRecordCount", value: "2000")
        ]
        guard let url = components.url else { throw ArcGISError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    // MARK: - Shared helpers

    private func fetchCount(from baseURL: String) async throws -> Int {
        var components = URLComponents(string: "\(baseURL)/query")!
        components.queryItems = [
            URLQueryItem(name: "where", value: "1=1"),
            URLQueryItem(name: "returnCountOnly", value: "true"),
            URLQueryItem(name: "f", value: "json")
        ]
        guard let url = components.url else { throw ArcGISError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        return (try JSONDecoder().decode(CountResponse.self, from: data)).count
    }

    private func fetchPage(from baseURL: String, fields: String, where whereClause: String,
                           offset: Int, pageSize: Int = 2000) async throws -> [GeoJSONFeature] {
        var components = URLComponents(string: "\(baseURL)/query")!
        components.queryItems = [
            URLQueryItem(name: "where", value: whereClause),
            URLQueryItem(name: "outFields", value: fields),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "f", value: "geojson"),
            URLQueryItem(name: "resultRecordCount", value: "\(pageSize)"),
            URLQueryItem(name: "resultOffset", value: "\(offset)")
        ]
        guard let url = components.url else { throw ArcGISError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        let collection = try JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data)
        return collection.features
    }
}

private struct CountResponse: Decodable {
    let count: Int
}
