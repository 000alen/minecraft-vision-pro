import Foundation

// Single source of truth for the LAN stream wire format, shared by the macOS host
// (`VisionCraftHost`) and the visionOS companion (`VisionCraftCompanion`). The two are separate
// apps with no common binary framework, so this file is compiled into *both* targets via XcodeGen
// (`sources: ../shared/Sources`). Keeping one copy guarantees the framing and discovery constants
// can never drift out of byte-compatibility between sender and receiver.

/// Envelope framing for `bridge/stream-protocol.md`:
/// `[length u32 BE][type u8][payload (length-1 bytes)]`. `length` counts type + payload.
enum StreamMessageType: UInt8 {
    case hello = 0x01
    case ping = 0x02
    case pong = 0x03
    case videoConfig = 0x10
    case videoFrame = 0x11
    case uplink = 0x20
    case requestIdr = 0x21
    case downlink = 0x22
    case bye = 0x30
}

enum StreamProtocol {
    // MARK: Discovery

    /// TCP port the host listens on and the companion connects to by default.
    static let defaultPort: UInt16 = 19736
    /// Bonjour service type the host advertises and the companion browses for.
    static let bonjourServiceType = "_visioncraft-stream._tcp"

    // MARK: Framing

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

    // MARK: VIDEO_FRAME payload  `[u32 metaLen BE][meta JSON][HEVC access unit]`

    /// Producer side (host): build a `VIDEO_FRAME` payload from its parts.
    static func videoFramePayload(metaJSON: String, accessUnit: Data) -> Data {
        let meta = Data(metaJSON.utf8)
        var out = Data(capacity: 4 + meta.count + accessUnit.count)
        var metaLen = UInt32(meta.count).bigEndian
        withUnsafeBytes(of: &metaLen) { out.append(contentsOf: $0) }
        out.append(meta)
        out.append(accessUnit)
        return out
    }

    /// A decoded `videoFrame` payload.
    struct VideoFramePayload {
        let meta: [String: Any]
        let accessUnit: Data
    }

    /// Consumer side (companion): split a `VIDEO_FRAME` payload into meta + access unit.
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
    enum FramerError: Error {
        case messageTooLarge(Int)
        case invalidLength(Int)
        case unknownMessageType(UInt8)
    }

    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    /// Discard any partially-buffered bytes. Call when reconnecting so a half-message from a dead
    /// connection can't desync the framer on the fresh one.
    func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Returns the next complete message, or nil if more bytes are needed. Throws if a length
    /// prefix exceeds the protocol maximum (caller should drop the connection).
    func next() throws -> (type: StreamMessageType, payload: Data)? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length >= 1 else {
            throw FramerError.invalidLength(length)
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
            throw FramerError.unknownMessageType(typeByte)
        }
        return (type, payload)
    }
}
