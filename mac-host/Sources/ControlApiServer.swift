import Foundation
import Network

/// Loopback-only HTTP control surface for simulator/device automation.
final class ControlApiServer {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: String
    }

    struct Response {
        let status: Int
        let body: String

        static func json(status: Int = 200, _ body: String) -> Response {
            Response(status: status, body: body)
        }
    }

    typealias Handler = @MainActor (Request) async -> Response

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "visioncraft.control-api")
    private var handler: Handler?

    func start(port: Int, handler: @escaping Handler) throws {
        if listener != nil {
            self.handler = handler
            return
        }

        guard let portValue = UInt16(exactly: port), portValue > 0 else {
            throw BridgeServerError.invalidPort(port)
        }

        self.handler = handler
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: portValue)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        handler = nil
    }

    private func accept(_ connection: NWConnection) {
        // Loopback-only: this control surface can start/stop the bridge and open the
        // immersive space, so it must never be reachable from off-box.
        guard JavaBridgeServer.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            guard let data,
                  let raw = String(data: data, encoding: .utf8),
                  let request = Self.parse(raw) else {
                self.send(.json(status: 400, #"{"error":"bad_request"}"#), on: connection)
                return
            }

            Task { [handler] in
                let response = await handler?(request) ?? .json(status: 503, #"{"error":"unavailable"}"#)
                self.send(response, on: connection)
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reason = Self.reasonPhrase(for: response.status)
        let bodyData = Data(response.body.utf8)
        let header = """
        HTTP/1.1 \(response.status) \(reason)\r
        Content-Type: application/json\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """

        var payload = Data(header.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parse(_ raw: String) -> Request? {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let head = parts.first ?? raw
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        guard let requestLine = head.components(separatedBy: "\r\n").first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }

        let method = requestParts[0].uppercased()
        let target = requestParts[1]
        let urlParts = target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = urlParts.first ?? "/"
        let query = urlParts.count > 1 ? parseQuery(urlParts[1]) : [:]
        return Request(method: method, path: path, query: query, body: body)
    }

    private static func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = pieces.first?.removingPercentEncoding else { continue }
            let value = pieces.count > 1 ? pieces[1].removingPercentEncoding ?? "" : ""
            result[key] = value
        }
        return result
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "OK"
        }
    }
}
