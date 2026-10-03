// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Минимальный HTTP-сервер на Network.framework (NWListener).
// Парсит запрос, вызывает handler, отдаёт JSON-ответ.
// Поддерживает SSE через onSseOpen/onSseClose.

import Foundation
import Network

@available(iOS 17.0, *)
final class HttpServer {

    typealias Handler = (_ method: String, _ path: String, _ body: String) -> (Int, String)
    typealias SseSend = (String) -> Void
    typealias SseOpenHandler = (@escaping SseSend) -> UUID
    typealias SseCloseHandler = (UUID) -> Void

    private let host: String
    private let port: UInt16
    private let handler: Handler
    private let onSseOpen: SseOpenHandler
    private let onSseClose: SseCloseHandler

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "lalune.http", attributes: .concurrent)

    init(host: String, port: UInt16,
         handler: @escaping Handler,
         onSseOpen: @escaping SseOpenHandler,
         onSseClose: @escaping SseCloseHandler) {
        self.host = host
        self.port = port
        self.handler = handler
        self.onSseOpen = onSseOpen
        self.onSseClose = onSseClose
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = true

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[HTTP] listening on \(self.host):\(self.port)")
                case .failed(let e):
                    print("[HTTP] failed: \(e)")
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("[HTTP] start error: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn)
    }

    private func readRequest(_ conn: NWConnection, buffer: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }

            // Проверяем, получены ли заголовки
            if let headerEnd = self.findHeaderEnd(buf) {
                let headerData = buf[..<headerEnd.lowerBound]
                let headerStr = String(data: headerData, encoding: .utf8) ?? ""
                let contentLength = self.parseContentLength(headerStr)
                let bodyStart = headerEnd.upperBound

                if buf.count - bodyStart >= contentLength {
                    let bodyData = buf[bodyStart..<(bodyStart + contentLength)]
                    let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
                    self.processRequest(headerStr, bodyStr, conn)
                    return
                }
            }

            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.readRequest(conn, buffer: buf)
        }
    }

    private func findHeaderEnd(_ data: Data) -> Range<Data.Index>? {
        let pattern = Data([0x0d, 0x0a, 0x0d, 0x0a])
        return data.range(of: pattern)
    }

    private func parseContentLength(_ headers: String) -> Int {
        for line in headers.split(separator: "\r\n") {
            let l = line.lowercased()
            if l.hasPrefix("content-length:") {
                let v = l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(v) ?? 0
            }
        }
        return 0
    }

    private func processRequest(_ headers: String, _ body: String, _ conn: NWConnection) {
        let lines = headers.split(separator: "\r\n")
        guard let first = lines.first else { conn.cancel(); return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }

        let method = String(parts[0])
        let path = String(parts[1])

        if path.hasPrefix("/events") || path.hasPrefix("/logs/stream") {
            startSse(conn)
            return
        }

        let (code, bodyStr) = handler(method, path, body)
        sendResponse(conn, code: code, body: bodyStr, contentType: "application/json; charset=utf-8")
    }

    private func sendResponse(_ conn: NWConnection, code: Int, body: String, contentType: String) {
        let bodyData = body.data(using: .utf8) ?? Data()
        var response = "HTTP/1.1 \(code) \(statusText(code))\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Access-Control-Allow-Methods: GET,POST,PUT,PATCH,DELETE,OPTIONS\r\n"
        response += "Access-Control-Allow-Headers: *\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var out = response.data(using: .utf8) ?? Data()
        out.append(bodyData)

        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }

    private func startSse(_ conn: NWConnection) {
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: keep-alive\r
        Access-Control-Allow-Origin: *\r
        \r

        """
        conn.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })

        let send: SseSend = { payload in
            let msg = "data: \(payload)\n\n"
            conn.send(content: msg.data(using: .utf8), completion: .contentProcessed { _ in })
        }

        let id = onSseOpen(send)

        // Пингуем каждые 15 сек, пока соединение живо
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
            send("{\"type\":\"ping\"}")
            _ = self // оставляем соединение открытым, реальное закрытие — по ошибке NWConnection
        }
    }
}
