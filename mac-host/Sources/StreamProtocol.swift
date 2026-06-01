import Foundation

/// Mac side of `bridge/stream-protocol.md` envelope framing:
/// `[length u32 BE][type u8][payload (length-1 bytes)]`. `length` counts type + payload.
///
/// This mirrors the visionOS companion's `StreamProtocol.swift`; the two targets don't share a
/// module, so the framing is intentionally duplicated and must stay byte-compatible.
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

    /// Build a `VIDEO_FRAME` payload: `[u32 metaLen BE][meta JSON][HEVC access unit]`.
    static func videoFramePayload(metaJSON: String, accessUnit: Data) -> Data {
        let meta = Data(metaJSON.utf8)
        var out = Data(capacity: 4 + meta.count + accessUnit.count)
        var metaLen = UInt32(meta.count).bigEndian
        withUnsafeBytes(of: &metaLen) { out.append(contentsOf: $0) }
        out.append(meta)
        out.append(accessUnit)
        return out
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
            // Unknown type: already consumed; continue with the next message.
            return try next()
        }
        return (type, payload)
    }
}
