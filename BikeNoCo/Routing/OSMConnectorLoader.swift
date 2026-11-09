import Foundation
import CoreLocation

struct OSMConnectorEdge {
    let highwayClass: OSMHighwayClass
    let name: String?
    let isBridge: Bool
    let isTunnel: Bool
    let startNodeID: Int64
    let endNodeID: Int64
    let coordinates: [CLLocationCoordinate2D]
}

struct OSMConnectorFile {
    struct Meta {
        let source: String
        let osmTimestamp: String
        let attribution: String
    }

    let meta: Meta
    let edges: [OSMConnectorEdge]
}

enum OSMConnectorLoader {
    private static let quantize = 1e5

    static func loadBundled(bundle: Bundle = .main) throws -> OSMConnectorFile {
        guard let url = bundle.url(forResource: "osm_connectors", withExtension: "json") else {
            throw LoaderError.missingResource
        }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> OSMConnectorFile {
        let raw = try JSONDecoder().decode(RawFile.self, from: data)
        let rawEdges = raw.edges
        var decoded = [OSMConnectorEdge?](repeating: nil, count: rawEdges.count)
        var firstError: Error?
        let errorLock = NSLock()
        decoded.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: rawEdges.count) { index in
                do {
                    buffer[index] = try decodeEdge(rawEdges[index])
                } catch {
                    errorLock.lock()
                    if firstError == nil { firstError = error }
                    errorLock.unlock()
                }
            }
        }
        if let firstError { throw firstError }
        let edges = decoded.compactMap { $0 }
        guard edges.count == rawEdges.count else { throw LoaderError.missingResource }
        return OSMConnectorFile(
            meta: OSMConnectorFile.Meta(
                source: raw.meta.source,
                osmTimestamp: raw.meta.osmTimestamp,
                attribution: raw.meta.attribution
            ),
            edges: edges
        )
    }

    /// Delta-decode interleaved lat/lon ints at 1e-5 degrees.
    static func decodeCoordinates(_ encoded: [Int]) -> [CLLocationCoordinate2D] {
        guard encoded.count >= 2, encoded.count % 2 == 0 else { return [] }
        var coords: [CLLocationCoordinate2D] = []
        coords.reserveCapacity(encoded.count / 2)
        var latI = 0
        var lonI = 0
        var index = 0
        while index < encoded.count {
            if index == 0 {
                latI = encoded[index]
                lonI = encoded[index + 1]
            } else {
                latI += encoded[index]
                lonI += encoded[index + 1]
            }
            coords.append(
                CLLocationCoordinate2D(
                    latitude: Double(latI) / quantize,
                    longitude: Double(lonI) / quantize
                )
            )
            index += 2
        }
        return coords
    }

    enum LoaderError: Error {
        case missingResource
        case unknownHighwayClass(String)
    }

    // MARK: - Codable raw

    private struct RawFile: Decodable {
        let meta: RawMeta
        let edges: [RawEdge]
    }

    private struct RawMeta: Decodable {
        let source: String
        let osmTimestamp: String
        let attribution: String

        enum CodingKeys: String, CodingKey {
            case source
            case osmTimestamp = "osm_timestamp"
            case attribution
        }
    }

    private struct RawEdge: Decodable {
        let h: String
        let n: String?
        let b: Int?
        let t: Int?
        let a: Int64
        let z: Int64
        let c: [Int]
    }

    private static func decodeEdge(_ raw: RawEdge) throws -> OSMConnectorEdge {
        guard let highway = OSMHighwayClass.from(raw.h) else {
            throw LoaderError.unknownHighwayClass(raw.h)
        }
        return OSMConnectorEdge(
            highwayClass: highway,
            name: raw.n,
            isBridge: (raw.b ?? 0) != 0,
            isTunnel: (raw.t ?? 0) != 0,
            startNodeID: raw.a,
            endNodeID: raw.z,
            coordinates: decodeCoordinates(raw.c)
        )
    }
}
