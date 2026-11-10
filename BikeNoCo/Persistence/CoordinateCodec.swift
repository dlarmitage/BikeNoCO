import Foundation
import CoreLocation
import Compression

/// Compact waypoint storage: delta-encoded lat/lon at 1e-6°, lzfse-compressed.
enum CoordinateCodec {
    private static let magic: [UInt8] = [0x42, 0x4E, 0x43, 0x4F] // "BNCO"
    private static let version: UInt8 = 1
    private static let microDegrees = 1_000_000.0

    static func encode(_ coordinates: [CLLocationCoordinate2D]) throws -> Data {
        var payload = Data()
        payload.append(contentsOf: magic)
        payload.append(version)

        var count = UInt32(coordinates.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }

        guard let first = coordinates.first else {
            return try compress(payload)
        }

        var prevLat = Int32((first.latitude * microDegrees).rounded())
        var prevLon = Int32((first.longitude * microDegrees).rounded())

        for (index, coordinate) in coordinates.enumerated() {
            let lat = Int32((coordinate.latitude * microDegrees).rounded())
            let lon = Int32((coordinate.longitude * microDegrees).rounded())
            if index == 0 {
                appendInt32(lat, to: &payload)
                appendInt32(lon, to: &payload)
            } else {
                appendInt32(lat &- prevLat, to: &payload)
                appendInt32(lon &- prevLon, to: &payload)
            }
            prevLat = lat
            prevLon = lon
        }

        return try compress(payload)
    }

    static func decode(_ data: Data) throws -> [CLLocationCoordinate2D] {
        let payload = try decompress(data)
        var offset = 0

        guard payload.count >= 4 + 1 + 4 else { throw TrackCodec.CodecError.truncated }
        guard Array(payload[offset..<offset + 4]) == magic else {
            throw TrackCodec.CodecError.badMagic
        }
        offset += 4

        let fileVersion = payload[offset]
        offset += 1
        guard fileVersion == version else {
            throw TrackCodec.CodecError.unsupportedVersion(fileVersion)
        }

        let count = Int(readUInt32(payload, &offset))
        if count == 0 { return [] }

        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(count)
        var lat: Int32 = 0
        var lon: Int32 = 0

        for index in 0..<count {
            guard payload.count >= offset + 8 else { throw TrackCodec.CodecError.truncated }
            if index == 0 {
                lat = readInt32(payload, &offset)
                lon = readInt32(payload, &offset)
            } else {
                lat &+= readInt32(payload, &offset)
                lon &+= readInt32(payload, &offset)
            }
            result.append(
                CLLocationCoordinate2D(
                    latitude: Double(lat) / microDegrees,
                    longitude: Double(lon) / microDegrees
                )
            )
        }
        return result
    }

    private static func compress(_ data: Data) throws -> Data {
        let dstSize = data.count + data.count / 16 + 64
        var destination = Data(count: dstSize)
        let written: Int = try destination.withUnsafeMutableBytes { dstRaw in
            try data.withUnsafeBytes { srcRaw in
                guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                      let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else {
                    throw TrackCodec.CodecError.compressionFailed
                }
                let n = compression_encode_buffer(dst, dstSize, src, data.count, nil, COMPRESSION_LZFSE)
                guard n > 0 else { throw TrackCodec.CodecError.compressionFailed }
                return n
            }
        }
        destination.count = written
        return destination
    }

    private static func decompress(_ data: Data) throws -> Data {
        var capacity = max(data.count * 8, 1_024)
        for _ in 0..<4 {
            var destination = Data(count: capacity)
            let written: Int = destination.withUnsafeMutableBytes { dstRaw in
                data.withUnsafeBytes { srcRaw in
                    guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                          let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_decode_buffer(dst, capacity, src, data.count, nil, COMPRESSION_LZFSE)
                }
            }
            if written > 0 {
                destination.count = written
                return destination
            }
            capacity *= 2
        }
        throw TrackCodec.CodecError.decompressionFailed
    }

    private static func appendInt32(_ value: Int32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func readInt32(_ data: Data, _ offset: inout Int) -> Int32 {
        let value: Int32 = data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: Int32.self).bigEndian
        }
        offset += 4
        return value
    }

    private static func readUInt32(_ data: Data, _ offset: inout Int) -> UInt32 {
        let value: UInt32 = data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
        offset += 4
        return value
    }
}
