import Foundation
import KerfCore

/// HTTP calls to an xTool D1 / D1 Pro over Wi-Fi. See `XToolWiFi` for the protocol.
struct XToolWiFiClient: Sendable {
    let base: URL

    enum Failure: LocalizedError {
        case unreachable(String)
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .unreachable(let s): return s
            case .refused(let s): return s
            }
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.timeoutIntervalForResource = 120
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func get(_ url: URL, timeout: TimeInterval = 5) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        do {
            let (data, _) = try await Self.session.data(for: req)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw Failure.unreachable("Can't reach the laser at \(base.host ?? "?"): \(error.localizedDescription)")
        }
    }

    func ping() async throws {
        let reply = try await get(XToolWiFi.pingURL(base))
        guard XToolWiFi.isOK(reply) else { throw Failure.refused("Unexpected answer from the laser: \(reply)") }
    }

    func firmware() async -> XToolFirmware? {
        guard let reply = try? await get(XToolWiFi.versionURL(base)) else { return nil }
        return XToolWiFi.firmware(fromVersionReply: reply)
    }

    func workingState() async throws -> XToolWorkingState {
        let reply = try await get(XToolWiFi.workingStateURL(base))
        guard let state = XToolWiFi.workingState(reply) else { throw Failure.refused("Unexpected status: \(reply)") }
        return state
    }

    func command(_ line: String) async throws {
        guard let url = XToolWiFi.commandURL(base, line: line) else { return }
        let reply = try await get(url)
        guard XToolWiFi.isOK(reply) else { throw Failure.refused("The laser rejected “\(line)”: \(reply)") }
    }

    func upload(_ text: String) async throws {
        let boundary = "KerfBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var req = URLRequest(url: XToolWiFi.uploadURL(base))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = XToolWiFi.multipartBody(text, boundary: boundary)
        let reply: String
        do {
            let (data, _) = try await Self.session.upload(for: req, from: body)
            reply = String(decoding: data, as: UTF8.self)
        } catch {
            throw Failure.unreachable("Upload to the laser failed: \(error.localizedDescription)")
        }
        guard XToolWiFi.isOK(reply) else { throw Failure.refused("The laser refused the upload: \(reply)") }
    }

    func start() async throws {
        _ = try await get(XToolWiFi.startURL(base))
    }

    /// True when the laser accepted the action (it answers fail when the action doesn't fit its state).
    func action(_ a: XToolWiFi.JobAction) async throws -> Bool {
        XToolWiFi.isOK(try await get(XToolWiFi.actionURL(base, a)))
    }
}
