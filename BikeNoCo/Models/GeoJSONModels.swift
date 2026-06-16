import CoreLocation

struct GeoJSONFeatureCollection: Decodable {
    let features: [GeoJSONFeature]
}

struct GeoJSONFeature: Decodable {
    let geometry: GeoJSONGeometry?
    let properties: RouteProperties?
}

struct GeoJSONTrailFeature: Decodable {
    let geometry: GeoJSONGeometry?
    let properties: TrailProperties?

    private enum CodingKeys: String, CodingKey { case geometry, properties }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Use try? so a bad geometry or unexpected property type yields nil, not a throw
        geometry   = try? c.decodeIfPresent(GeoJSONGeometry.self,  forKey: .geometry)
        properties = try? c.decodeIfPresent(TrailProperties.self,   forKey: .properties)
    }
}

// One bad record must not abort the entire collection
private struct _FailableTrailFeature: Decodable {
    let value: GeoJSONTrailFeature?
    init(from decoder: Decoder) throws { value = try? GeoJSONTrailFeature(from: decoder) }
}

struct GeoJSONTrailFeatureCollection: Decodable {
    let features: [GeoJSONTrailFeature]

    private enum CodingKeys: String, CodingKey { case features }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        features = try c.decode([_FailableTrailFeature].self, forKey: .features)
            .compactMap { $0.value }
    }
}

struct GeoJSONGeometry: Decodable {
    let type: String
    let coordinates: CoordinateTree

    enum CodingKeys: String, CodingKey {
        case type, coordinates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        coordinates = (try? container.decode(CoordinateTree.self, forKey: .coordinates)) ?? .point([])
    }
}

indirect enum CoordinateTree: Decodable {
    case point([Double])
    case line([[Double]])
    case multiLine([[[Double]]])

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let first = try? container.decode([Double].self) {
            var rest: [[Double]] = [first]
            while !container.isAtEnd {
                if let pair = try? container.decode([Double].self) {
                    rest.append(pair)
                } else {
                    // deeper nesting — restart
                    break
                }
            }
            // single coordinate pair → point
            if rest.count == 1 && rest[0].count <= 3 {
                self = .point(rest[0])
            } else {
                self = .line(rest)
            }
        } else if let first = try? container.decode([[Double]].self) {
            var rest: [[[Double]]] = [first]
            while !container.isAtEnd {
                if let ring = try? container.decode([[Double]].self) {
                    rest.append(ring)
                } else {
                    break
                }
            }
            self = .multiLine(rest)
        } else {
            self = .point([])
        }
    }

    var paths: [[CLLocationCoordinate2D]] {
        switch self {
        case .point(let pair):
            guard pair.count >= 2 else { return [] }
            return [[CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])]]
        case .line(let pairs):
            let coords = pairs.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            }
            return [coords]
        case .multiLine(let lines):
            return lines.map { pairs in
                pairs.compactMap { pair -> CLLocationCoordinate2D? in
                    guard pair.count >= 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
                }
            }
        }
    }
}

struct TrailProperties: Decodable {
    let objectId: Int?
    let name: String?
    let category: String?
    let constructionType: String?
    let surface: String?
    let bikeUse: String?

    private enum CodingKeys: String, CodingKey {
        case objectId = "OBJECTID"
        case name = "NAME"
        case category = "CATEGORY"
        case constructionType = "CONSTRUCTIONTYPE"
        case surface = "SURFACE"
        case bikeUse = "BIKEUSE"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Use try? per field so an unexpected type on one field doesn't kill the whole record
        objectId         = try? c.decodeIfPresent(Int.self,    forKey: .objectId)
        name             = try? c.decodeIfPresent(String.self, forKey: .name)
        category         = try? c.decodeIfPresent(String.self, forKey: .category)
        constructionType = try? c.decodeIfPresent(String.self, forKey: .constructionType)
        surface          = try? c.decodeIfPresent(String.self, forKey: .surface)
        // BIKEUSE may be a String ("Yes") or an Int (1/0) depending on ArcGIS config
        if let s = try? c.decodeIfPresent(String.self, forKey: .bikeUse) {
            bikeUse = s
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .bikeUse) {
            bikeUse = i == 1 ? "Yes" : "No"
        } else {
            bikeUse = nil
        }
    }
}

// MARK: - Generic GeoJSON collection (used by Loveland layers)

/// Failable wrapper so one bad record never aborts the full array decode.
private struct GFWrapper<P: Decodable>: Decodable {
    let value: GFFeature<P>?
    init(from decoder: Decoder) throws { value = try? GFFeature<P>(from: decoder) }
}

struct GFFeature<P: Decodable>: Decodable {
    let geometry: GeoJSONGeometry?
    let properties: P?

    private enum CodingKeys: String, CodingKey { case geometry, properties }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        geometry   = try? c.decodeIfPresent(GeoJSONGeometry.self, forKey: .geometry)
        properties = try? c.decodeIfPresent(P.self,               forKey: .properties)
    }
}

struct GFCollection<P: Decodable>: Decodable {
    let features: [GFFeature<P>]

    private enum CodingKeys: String, CodingKey { case features }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        features = try c.decode([GFWrapper<P>].self, forKey: .features)
            .compactMap { $0.value }
    }
}

// MARK: - Loveland property types

struct LovelandBikewayProperties: Decodable {
    let objectId: Int?
    let fullStName: String?

    private enum CodingKeys: String, CodingKey {
        case objectId = "OBJECTID"; case fullStName = "FULLSTNAME"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectId   = try? c.decodeIfPresent(Int.self,    forKey: .objectId)
        fullStName = try? c.decodeIfPresent(String.self, forKey: .fullStName)
    }
}

struct LovelandBikeRouteProperties: Decodable {
    let objectId: Int?
    let fullStName: String?

    private enum CodingKeys: String, CodingKey {
        case objectId = "OBJECTID"; case fullStName = "FULLSTNAME"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectId   = try? c.decodeIfPresent(Int.self,    forKey: .objectId)
        fullStName = try? c.decodeIfPresent(String.self, forKey: .fullStName)
    }
}

struct LovelandRecTrailProperties: Decodable {
    let objectId: Int?
    let typeName: String?
    let altTrailName: String?
    let surfaceType: String?

    private enum CodingKeys: String, CodingKey {
        case objectId = "OBJECTID"; case typeName = "TYPE"
        case altTrailName = "ALTTRAILNAME"; case surfaceType = "SURFACETYPE"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectId     = try? c.decodeIfPresent(Int.self,    forKey: .objectId)
        typeName     = try? c.decodeIfPresent(String.self, forKey: .typeName)
        altTrailName = try? c.decodeIfPresent(String.self, forKey: .altTrailName)
        surfaceType  = try? c.decodeIfPresent(String.self, forKey: .surfaceType)
    }
}

struct LovelandParkTrailProperties: Decodable {
    let objectId: Int?
    let name: String?
    let surfType: String?
    let mainType: String?
    let roadCycle: String?
    let mtbCycle: String?

    private enum CodingKeys: String, CodingKey {
        case objectId = "OBJECTID"; case name = "NAME"
        case surfType = "SURFTYPE"; case mainType = "MAIN_TYPE"
        case roadCycle = "ROADCYCLE"; case mtbCycle = "MTBCYCLE"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectId  = try? c.decodeIfPresent(Int.self,    forKey: .objectId)
        name      = try? c.decodeIfPresent(String.self, forKey: .name)
        surfType  = try? c.decodeIfPresent(String.self, forKey: .surfType)
        mainType  = try? c.decodeIfPresent(String.self, forKey: .mainType)
        roadCycle = try? c.decodeIfPresent(String.self, forKey: .roadCycle)
        mtbCycle  = try? c.decodeIfPresent(String.self, forKey: .mtbCycle)
    }
}

// MARK: - Fort Collins route properties

struct RouteProperties: Decodable {
    let objectId: Int?
    let bikeInfraType: String?
    let strName: String?
    let lts: Int?
    let mapSymbolClass: String?
    let bikewayName: String?
    let speedLimit: Int?

    enum CodingKeys: String, CodingKey {
        case objectId = "OBJECTID"
        case bikeInfraType = "BIKEINFRA_TYPE"
        case strName = "STRNAME"
        case lts = "LTS"
        case mapSymbolClass = "MAPSYMBOLCLASS"
        case bikewayName = "BIKEWAYNAME"
        case speedLimit = "SPEEDLIMIT"
    }
}
