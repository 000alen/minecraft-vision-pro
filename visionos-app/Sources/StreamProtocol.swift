import Foundation

/// Envelope framing for `bridge/stream-protocol.md`:
/// `[length u32 BE][type u8][payload (length-1 bytes)]`. `length` counts type + payload.
enum StreamMessageType: UInt8 {
    case hello = 0x01
    case ping = 0x02
    case pong = 0x03
    case videoConfig = 0x10
    case videoFrame = 0x11
    case uplink = 0x20
    case bye = 0x30
}

enum StreamProtocol {
    /// Max envelope `length`. A larger value is treated as a desync / hostile peer.
    static let maxMessageLength = 64 * 1024 * 1024

    /// Build a complete envelope ready to send.
    static func encode(_ type: StreamMessageType, payload: Data) -> Data {
        var out = Data(capacity: 5 + payload.count)
        var length = UInt32(1 + payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    static func encode(_ type: StreamMessageType, json: String) -> Data {
        encode(type, payload: Data(json.utf8))
    }

    /// A decoded `videoFrame` payload: `[u32 metaLen BE][meta JSON][HEVC access unit]`.
    struct VideoFramePayload {
        let meta: [String: Any]
        let accessUnit: Data
    }

    static func parseVideoFrame(_ payload: Data) -> VideoFramePayload? {
        guard payload.count >= 4 else { return nil }
        let metaLen = payload.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let metaStart = payload.index(payload.startIndex, offsetBy: 4)
        guard metaLen <= payload.count - 4 else { return nil }
        let metaEnd = payload.index(metaStart, offsetBy: Int(metaLen))
        let metaData = payload[metaStart..<metaEnd]
        guard let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else { return nil }
        return VideoFramePayload(meta: meta, accessUnit: Data(payload[metaEnd...]))
    }
}

/// Incremental envelope reader. Append received bytes, then drain complete messages.
final class StreamFramer {
    enum FramerError: Error { case messageTooLarge(Int) }

    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete message, or nil if more bytes are needed. Throws if a length
    /// prefix exceeds the protocol maximum (caller should drop the connection).
    func next() throws -> (type: StreamMessageType, payload: Data)? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length >= 1 else {
            // length must cover at least the type byte
            buffer.removeAll(keepingCapacity: true)
            return nil
        }
        guard length <= StreamProtocol.maxMessageLength else {
            throw FramerError.messageTooLarge(length)
        }
        guard buffer.count >= 4 + length else { return nil }

        let typeByte = buffer[buffer.index(buffer.startIndex, offsetBy: 4)]
        let payloadStart = buffer.index(buffer.startIndex, offsetBy: 5)
        let payloadEnd = buffer.index(buffer.startIndex, offsetBy: 4 + length)
        let payload = Data(buffer[payloadStart..<payloadEnd])
        buffer.removeSubrange(buffer.startIndex..<payloadEnd)

        guard let type = StreamMessageType(rawValue: typeByte) else {
            // Unknown type: skip it (already consumed) and let the caller continue.
            return try next()
        }
        return (type, payload)
    }
}
