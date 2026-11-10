import Foundation
import CoreLocation
import Compression

/// Compact, delta-encoded track storage: coordinates at 1e-6°, altitude, speed,
/// timestamp offsets, then lzfse-compressed.
enum TrackCodec {
    private static let magic: [UInt8] = [0x42, 0x4E, 0x54, 0x52] // "BNTR"
    private static let version: UInt8 = 1
    private static let microDegrees = 1_000_000.0
    private static let altitudeScale = 100.0      // cm
    private static let speedScale = 1_000.0       // mm/s
    private static let accuracyScale = 100.0      // cm

    static func encode(_ points: [TrackPoint]) throws -> Data {
        var payload = Data()
        payload.append(contentsOf: magic)
        payload.append(version)

        var count = UInt32(points.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }

        guard let first = points.first else {
            return try compress(payload)
        }

        var baseTime = first.timestamp.timeIntervalSince1970.bitPattern.bigEndian
        withUnsafeBytes(of: &baseTime) { payload.append(contentsOf: $0) }

        var prevLat = Int32((first.coordinate.latitude * microDegrees).rounded())
        var prevLon = Int32((first.coordinate.longitude * microDegrees).rounded())
        var prevTimeMs: Int64 = 0

        for (index, point) in points.enumerated() {
            let lat = Int32((point.coordinate.latitude * microDegrees).rounded())
            let lon = Int32((point.coordinate.longitude * microDegrees).rounded())
            let altitudeCm = Int32((point.altitude * altitudeScale).rounded())
            let speedMmps = Int32((max(point.speed, -1) * speedScale).rounded())
            let hAccCm = Int32((point.horizontalAccuracy * accuracyScale).rounded())
            let vAccCm = Int32((point.verticalAccuracy * accuracyScale).rounded())
            let timeMs = Int64(
                (point.timestamp.timeIntervalSince1970 - first.timestamp.timeIntervalSince1970) * 1000.0
            )

            if index == 0 {
                appendInt32(lat, to: &payload)
                appendInt32(lon, to: &payload)
            } else {
                appendInt32(lat &- prevLat, to: &payload)
                appendInt32(lon &- prevLon, to: &payload)
            }
            appendInt32(altitudeCm, to: &payload)
            appendInt32(speedMmps, to: &payload)
            appendInt32(hAccCm, to: &payload)
            appendInt32(vAccCm, to: &payload)
            appendInt32(Int32(clamping: timeMs &- prevTimeMs), to: &payload)

            prevLat = lat
            prevLon = lon
            prevTimeMs = timeMs
        }

        return try compress(payload)
    }

    static func decode(_ data: Data) throws -> [TrackPoint] {
        let payload = try decompress(data)
        var offset = 0

        guard payload.count >= 4 + 1 + 4 else {
            throw CodecError.truncated
        }
        guard Array(payload[offset..<offset + 4]) == magic else {
            throw CodecError.badMagic
        }
        offset += 4

        let fileVersion = payload[offset]
        offset += 1
        guard fileVersion == version else {
            throw CodecError.unsupportedVersion(fileVersion)
        }

        let count = Int(readUInt32(payload, &offset))
        guard count >= 0 else { throw CodecError.truncated }
        if count == 0 { return [] }

        guard payload.count >= offset + 8 else { throw CodecError.truncated }
        let baseBits = readUInt64(payload, &offset)
        let baseTime = Date(timeIntervalSince1970: Double(bitPattern: baseBits))

        var points: [TrackPoint] = []
        points.reserveCapacity(count)

        var lat: Int32 = 0
        var lon: Int32 = 0
        var timeMs: Int64 = 0

        for index in 0..<count {
            guard payload.count >= offset + 28 else { throw CodecError.truncated }
            if index == 0 {
                lat = readInt32(payload, &offset)
                lon = readInt32(payload, &offset)
            } else {
                lat &+= readInt32(payload, &offset)
                lon &+= readInt32(payload, &offset)
            }
            let altitudeCm = readInt32(payload, &offset)
            let speedMmps = readInt32(payload, &offset)
            let hAccCm = readInt32(payload, &offset)
            let vAccCm = readInt32(payload, &offset)
            timeMs &+= Int64(readInt32(payload, &offset))

            let speed = Double(speedMmps) / speedScale
            points.append(
                TrackPoint(
                    coordinate: CLLocationCoordinate2D(
                        latitude: Double(lat) / microDegrees,
                        longitude: Double(lon) / microDegrees
                    ),
                    altitude: Double(altitudeCm) / altitudeScale,
                    speed: speed < -0.5 ? -1 : speed,
                    timestamp: baseTime.addingTimeInterval(Double(timeMs) / 1000.0),
                    horizontalAccuracy: Double(hAccCm) / accuracyScale,
                    verticalAccuracy: Double(vAccCm) / accuracyScale
                )
            )
        }

        return points
    }

    // MARK: - Compression

    private static func compress(_ data: Data) throws -> Data {
        let dstSize = data.count + data.count / 16 + 64
        var destination = Data(count: dstSize)
        let written: Int = try destination.withUnsafeMutableBytes { dstRaw in
            try data.withUnsafeBytes { srcRaw in
                guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                      let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else {
                    throw CodecError.compressionFailed
                }
                let n = compression_encode_buffer(dst, dstSize, src, data.count, nil, COMPRESSION_LZFSE)
                guard n > 0 else { throw CodecError.compressionFailed }
                return n
            }
        }
        destination.count = written
        return destination
    }

    private static func decompress(_ data: Data) throws -> Data {
        // Tracks are small; allocate generously and grow if needed.
        var capacity = max(data.count * 8, 4_096)
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
        throw CodecError.decompressionFailed
    }

    // MARK: - Binary helpers

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

    private static func readUInt64(_ data: Data, _ offset: inout Int) -> UInt64 {
        let value: UInt64 = data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
        }
        offset += 8
        return value
    }

    enum CodecError: Error {
        case truncated
        case badMagic
        case unsupportedVersion(UInt8)
        case compressionFailed
        case decompressionFailed
    }
}
