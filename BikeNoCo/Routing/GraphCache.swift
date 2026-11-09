import Foundation
import CoreLocation
import CryptoKit

enum GraphCache {
    struct Payload: Codable {
        let key: String
        let osmTimestamp: String
        let projectionOriginLatitude: Double
        let projectionOriginLongitude: Double
        let nodes: [NodeDTO]
        let edges: [EdgeDTO]
    }

    struct NodeDTO: Codable {
        let id: Int
        let lat: Double
        let lon: Double
    }

    struct EdgeDTO: Codable {
        let id: Int
        let fromID: Int
        let toID: Int
        let lengthMeters: Double
        let facilityType: String
        let lts: Int?
        let name: String
        let sourceRouteID: UUID
        let isConnector: Bool
        let osmClass: String?
        let sourceObjectId: Int?
        let sourceLayer: String?
        /// Packed Float32 lat/lon pairs (little-endian).
        let coordinateData: Data
    }

    /// Stable key from ArcGIS identity tuples + OSM timestamp. Ignores `BikeRoute.id` UUIDs.
    static func makeKey(routes: [BikeRoute], osmTimestamp: String) -> String {
        let tuples = routes
            .filter { $0.facilityType != .recommendedRide }
            .map { route -> String in
                let pointCount = route.paths.reduce(0) { $0 + $1.count }
                return "\(route.sourceLayer)|\(route.objectId)|\(pointCount)"
            }
            .sorted()
        let joined = tuples.joined(separator: "\n") + "\nOSM:\(osmTimestamp)"
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("BikeNoCo", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL() throws -> URL {
        try cacheDirectory().appendingPathComponent("network_graph.bin")
    }

    static func load(expectedKey: String? = nil) throws -> (graph: BikeNetworkGraph, key: String, osmTimestamp: String)? {
        let url = try cacheURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let fileData = try Data(contentsOf: url, options: .mappedIfSafe)
        let payloadData = try decompress(fileData)
        let payload = try decodeBinaryPayload(payloadData)
        if let expectedKey, payload.key != expectedKey {
            return nil
        }
        return (decodeGraph(payload), payload.key, payload.osmTimestamp)
    }

    static func save(graph: BikeNetworkGraph, key: String, osmTimestamp: String) throws {
        let payload = encode(graph: graph, key: key, osmTimestamp: osmTimestamp)
        let raw = try encodeBinaryPayload(payload)
        let compressed = try compress(raw)
        try compressed.write(to: try cacheURL(), options: .atomic)
    }

    static func encode(graph: BikeNetworkGraph, key: String, osmTimestamp: String) -> Payload {
        Payload(
            key: key,
            osmTimestamp: osmTimestamp,
            projectionOriginLatitude: graph.projection.originLatitude,
            projectionOriginLongitude: graph.projection.originLongitude,
            nodes: graph.nodes.map {
                NodeDTO(id: $0.id, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude)
            },
            edges: graph.edges.map { edge in
                EdgeDTO(
                    id: edge.id,
                    fromID: edge.fromID,
                    toID: edge.toID,
                    lengthMeters: edge.lengthMeters,
                    facilityType: edge.facilityType.rawValue,
                    lts: edge.lts,
                    name: edge.name,
                    sourceRouteID: edge.sourceRouteID,
                    isConnector: edge.isConnector,
                    osmClass: edge.osmClass?.rawValue,
                    sourceObjectId: edge.sourceObjectId,
                    sourceLayer: edge.sourceLayer,
                    coordinateData: packCoordinates(edge.geometry)
                )
            }
        )
    }

    static func decodeGraph(_ payload: Payload) -> BikeNetworkGraph {
        var nodesByID: [Int: GraphNode] = [:]
        nodesByID.reserveCapacity(payload.nodes.count)
        for node in payload.nodes {
            nodesByID[node.id] = GraphNode(
                id: node.id,
                coordinate: CLLocationCoordinate2D(latitude: node.lat, longitude: node.lon)
            )
        }

        var edgesByID: [Int: GraphEdge] = [:]
        var adjacency: [Int: [Int]] = [:]
        edgesByID.reserveCapacity(payload.edges.count)
        for edge in payload.edges {
            let coords = unpackCoordinates(edge.coordinateData)
            let graphEdge = GraphEdge(
                id: edge.id,
                fromID: edge.fromID,
                toID: edge.toID,
                lengthMeters: edge.lengthMeters,
                geometry: coords,
                facilityType: FacilityType.from(edge.facilityType),
                lts: edge.lts,
                name: edge.name,
                sourceRouteID: edge.sourceRouteID,
                isConnector: edge.isConnector,
                osmClass: edge.osmClass.flatMap(OSMHighwayClass.from),
                sourceObjectId: edge.sourceObjectId,
                sourceLayer: edge.sourceLayer
            )
            edgesByID[edge.id] = graphEdge
            adjacency[edge.fromID, default: []].append(edge.id)
            if edge.fromID != edge.toID {
                adjacency[edge.toID, default: []].append(edge.id)
            }
        }

        return BikeNetworkGraph(
            nodesByID: nodesByID,
            edgesByID: edgesByID,
            adjacency: adjacency,
            projection: LocalProjection(
                originLatitude: payload.projectionOriginLatitude,
                originLongitude: payload.projectionOriginLongitude
            )
        )
    }

    // MARK: - Packed coordinates

    private static func packCoordinates(_ coordinates: [CLLocationCoordinate2D]) -> Data {
        var floats: [Float] = []
        floats.reserveCapacity(coordinates.count * 2)
        for coordinate in coordinates {
            floats.append(Float(coordinate.latitude))
            floats.append(Float(coordinate.longitude))
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func unpackCoordinates(_ data: Data) -> [CLLocationCoordinate2D] {
        let count = data.count / MemoryLayout<Float>.size
        guard count >= 2, count % 2 == 0 else { return [] }
        return data.withUnsafeBytes { raw -> [CLLocationCoordinate2D] in
            let floats = raw.bindMemory(to: Float.self)
            var coords: [CLLocationCoordinate2D] = []
            coords.reserveCapacity(count / 2)
            var i = 0
            while i + 1 < count {
                coords.append(
                    CLLocationCoordinate2D(
                        latitude: Double(floats[i]),
                        longitude: Double(floats[i + 1])
                    )
                )
                i += 2
            }
            return coords
        }
    }

    // MARK: - Binary payload (faster than PropertyList/JSON for large graphs)

    private static let binaryMagic = Data("BNCG".utf8)
    private static let binaryVersion: UInt32 = 1

    private static func encodeBinaryPayload(_ payload: Payload) throws -> Data {
        var data = Data()
        data.append(binaryMagic)
        appendUInt32(binaryVersion, to: &data)
        appendString(payload.key, to: &data)
        appendString(payload.osmTimestamp, to: &data)
        appendDouble(payload.projectionOriginLatitude, to: &data)
        appendDouble(payload.projectionOriginLongitude, to: &data)

        appendUInt32(UInt32(payload.nodes.count), to: &data)
        for node in payload.nodes {
            appendInt32(Int32(node.id), to: &data)
            appendDouble(node.lat, to: &data)
            appendDouble(node.lon, to: &data)
        }

        appendUInt32(UInt32(payload.edges.count), to: &data)
        for edge in payload.edges {
            appendInt32(Int32(edge.id), to: &data)
            appendInt32(Int32(edge.fromID), to: &data)
            appendInt32(Int32(edge.toID), to: &data)
            appendDouble(edge.lengthMeters, to: &data)
            appendString(edge.facilityType, to: &data)
            if let lts = edge.lts {
                appendUInt8(1, to: &data)
                appendInt32(Int32(lts), to: &data)
            } else {
                appendUInt8(0, to: &data)
            }
            appendString(edge.name, to: &data)
            appendString(edge.sourceRouteID.uuidString, to: &data)
            appendUInt8(edge.isConnector ? 1 : 0, to: &data)
            if let osmClass = edge.osmClass {
                appendUInt8(1, to: &data)
                appendString(osmClass, to: &data)
            } else {
                appendUInt8(0, to: &data)
            }
            if let objectId = edge.sourceObjectId {
                appendUInt8(1, to: &data)
                appendInt32(Int32(objectId), to: &data)
            } else {
                appendUInt8(0, to: &data)
            }
            if let layer = edge.sourceLayer {
                appendUInt8(1, to: &data)
                appendString(layer, to: &data)
            } else {
                appendUInt8(0, to: &data)
            }
            appendUInt32(UInt32(edge.coordinateData.count), to: &data)
            data.append(edge.coordinateData)
        }
        return data
    }

    private static func decodeBinaryPayload(_ data: Data) throws -> Payload {
        var offset = 0
        let magic = try readData(data, count: 4, offset: &offset)
        guard magic == binaryMagic else {
            throw NSError(domain: "GraphCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad cache magic"])
        }
        let version = try readUInt32(data, offset: &offset)
        guard version == binaryVersion else {
            throw NSError(domain: "GraphCache", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported cache version"])
        }
        let key = try readString(data, offset: &offset)
        let osmTimestamp = try readString(data, offset: &offset)
        let originLat = try readDouble(data, offset: &offset)
        let originLon = try readDouble(data, offset: &offset)

        let nodeCount = Int(try readUInt32(data, offset: &offset))
        var nodes: [NodeDTO] = []
        nodes.reserveCapacity(nodeCount)
        for _ in 0..<nodeCount {
            let id = Int(try readInt32(data, offset: &offset))
            let lat = try readDouble(data, offset: &offset)
            let lon = try readDouble(data, offset: &offset)
            nodes.append(NodeDTO(id: id, lat: lat, lon: lon))
        }

        let edgeCount = Int(try readUInt32(data, offset: &offset))
        var edges: [EdgeDTO] = []
        edges.reserveCapacity(edgeCount)
        for _ in 0..<edgeCount {
            let id = Int(try readInt32(data, offset: &offset))
            let fromID = Int(try readInt32(data, offset: &offset))
            let toID = Int(try readInt32(data, offset: &offset))
            let lengthMeters = try readDouble(data, offset: &offset)
            let facilityType = try readString(data, offset: &offset)
            let hasLTS = try readUInt8(data, offset: &offset) == 1
            let lts = hasLTS ? Int(try readInt32(data, offset: &offset)) : nil
            let name = try readString(data, offset: &offset)
            let uuidString = try readString(data, offset: &offset)
            let sourceRouteID = UUID(uuidString: uuidString) ?? UUID()
            let isConnector = try readUInt8(data, offset: &offset) == 1
            let hasOSM = try readUInt8(data, offset: &offset) == 1
            let osmClass = hasOSM ? try readString(data, offset: &offset) : nil
            let hasObjectId = try readUInt8(data, offset: &offset) == 1
            let sourceObjectId = hasObjectId ? Int(try readInt32(data, offset: &offset)) : nil
            let hasLayer = try readUInt8(data, offset: &offset) == 1
            let sourceLayer = hasLayer ? try readString(data, offset: &offset) : nil
            let coordCount = Int(try readUInt32(data, offset: &offset))
            let coordinateData = try readData(data, count: coordCount, offset: &offset)
            edges.append(
                EdgeDTO(
                    id: id,
                    fromID: fromID,
                    toID: toID,
                    lengthMeters: lengthMeters,
                    facilityType: facilityType,
                    lts: lts,
                    name: name,
                    sourceRouteID: sourceRouteID,
                    isConnector: isConnector,
                    osmClass: osmClass,
                    sourceObjectId: sourceObjectId,
                    sourceLayer: sourceLayer,
                    coordinateData: coordinateData
                )
            )
        }

        return Payload(
            key: key,
            osmTimestamp: osmTimestamp,
            projectionOriginLatitude: originLat,
            projectionOriginLongitude: originLon,
            nodes: nodes,
            edges: edges
        )
    }

    // MARK: - Compression

    private static func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .lzfse) as Data
    }

    private static func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzfse) as Data
    }

    // MARK: - Binary primitives

    private static func appendUInt8(_ value: UInt8, to data: inout Data) {
        data.append(value)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendInt32(_ value: Int32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendDouble(_ value: Double, to data: inout Data) {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let utf8 = Data(value.utf8)
        appendUInt32(UInt32(utf8.count), to: &data)
        data.append(utf8)
    }

    private static func readUInt8(_ data: Data, offset: inout Int) throws -> UInt8 {
        guard offset < data.count else { throw truncated() }
        defer { offset += 1 }
        return data[offset]
    }

    private static func readUInt32(_ data: Data, offset: inout Int) throws -> UInt32 {
        let raw = try readData(data, count: 4, offset: &offset)
        return raw.withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
    }

    private static func readInt32(_ data: Data, offset: inout Int) throws -> Int32 {
        let raw = try readData(data, count: 4, offset: &offset)
        return raw.withUnsafeBytes { Int32(littleEndian: $0.load(as: Int32.self)) }
    }

    private static func readDouble(_ data: Data, offset: inout Int) throws -> Double {
        let raw = try readData(data, count: 8, offset: &offset)
        let bits = raw.withUnsafeBytes { UInt64(littleEndian: $0.load(as: UInt64.self)) }
        return Double(bitPattern: bits)
    }

    private static func readString(_ data: Data, offset: inout Int) throws -> String {
        let count = Int(try readUInt32(data, offset: &offset))
        let raw = try readData(data, count: count, offset: &offset)
        return String(decoding: raw, as: UTF8.self)
    }

    private static func readData(_ data: Data, count: Int, offset: inout Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw truncated() }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    private static func truncated() -> NSError {
        NSError(domain: "GraphCache", code: 3, userInfo: [NSLocalizedDescriptionKey: "Truncated cache file"])
    }
}
