import Foundation
import SwiftUI
import UIKit

struct RemoteFile: Codable, Identifiable {
    let id: String
    let name: String
    let size: Int64
}
struct ServerInfo: Decodable { let name: String; let `protocol`: Int }
struct TransferError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
final class ProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    let update: (Double) -> Void
    init(update: @escaping (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { update(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { update(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
}

@MainActor
final class TransferModel: ObservableObject {
    @Published var address = ""
    @Published var secret = ""
    @Published var connected = false
    @Published var computer = ""
    @Published var files: [RemoteFile] = []
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = "Pair with Windows to get started."
    @Published var received: [URL] = []
    private var pairedURL: URL?
    private var pairedSecret = ""
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: ProgressDelegate { _ in }, delegateQueue: nil)
    }()
    init() { refreshReceived() }
    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    func refreshReceived() {
        received = ((try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let base = pairedURL else { throw TransferError(message: "Connect to Windows first.") }
        var parts = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer " + pairedSecret, forHTTPHeaderField: "Authorization")
        return request
    }
    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let reason: String
            switch code {
            case 401: reason = "Pairing secret rejected. Copy the current secret from Windows."
            case 404: reason = "This file is no longer shared. Refresh the list."
            case 413: reason = "File exceeds the 100 GB transfer limit."
            case 429: reason = "Windows is busy receiving files. Try again shortly."
            case 507: reason = "Windows does not have enough free disk space."
            default: reason = "Transfer failed (HTTP \(code)). Please retry."
            }
            throw TransferError(message: reason)
        }
    }
    func connect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        connected = false
        do {
            let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: value), url.scheme == "http", let host = url.host,
                  Self.isPrivateIPv4(host), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
                throw TransferError(message: "Enter the private IPv4 address shown on Windows, such as http://192.168.1.20:45872.")
            }
            pairedURL = url; pairedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let (data, response) = try await session.data(for: request("v1/info"))
            try check(response)
            let info = try JSONDecoder().decode(ServerInfo.self, from: data)
            guard info.protocol == 1 else { throw TransferError(message: "Incompatible Windows app version.") }
            computer = info.name; connected = true
            try await fetchFiles()
            status = "Connected to \(computer)."
        } catch { connected = false; pairedURL = nil; pairedSecret = ""; status = error.localizedDescription }
    }
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
    }
    private func fetchFiles() async throws {
        let (data, response) = try await session.data(for: request("v1/files"))
        try check(response)
        files = try JSONDecoder().decode([RemoteFile].self, from: data)
    }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await fetchFiles() } catch { status = error.localizedDescription }
    }
    private func progressDelegate() -> ProgressDelegate {
        ProgressDelegate { [weak self] value in Task { @MainActor in self?.progress = value } }
    }
    @discardableResult
    func send(_ urls: [URL]) async -> Bool {
        guard !busy, connected else { return false }
        busy = true; UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        var completed = 0
        do {
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                progress = 0; status = "Sending \(url.lastPathComponent)…"
                var req = try request("v1/upload", query: [URLQueryItem(name: "name", value: url.lastPathComponent)])
                req.httpMethod = "POST"
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                req.setValue(String(size), forHTTPHeaderField: "Content-Length")
                let start = Date()
                let (_, response) = try await session.upload(for: req, fromFile: url, delegate: progressDelegate())
                try check(response); completed += 1; progress = 1
                let speed = Double(size) / max(Date().timeIntervalSince(start), 0.001) / 1_000_000
                status = String(format: "Sent %d of %d files · %.1f MB/s", completed, urls.count, speed)
            }
            return true
        } catch { status = "Sent \(completed) of \(urls.count). \(error.localizedDescription)"; return false }
    }
    func download(_ file: RemoteFile) async {
        guard !busy else { return }; busy = true; progress = 0
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        status = "Receiving \(file.name)…"
        do {
            let (temp, response) = try await session.download(for: request("v1/files/\(file.id)"), delegate: progressDelegate())
            defer { try? FileManager.default.removeItem(at: temp) }
            try check(response)
            let cleanName = file.name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "file"
            var target = documents.appendingPathComponent(cleanName)
            if FileManager.default.fileExists(atPath: target.path) { target = documents.appendingPathComponent(UUID().uuidString + "_" + cleanName) }
            try FileManager.default.moveItem(at: temp, to: target)
            progress = 1; status = "Received \(file.name). Open or save it below."; refreshReceived()
        } catch { status = error.localizedDescription }
    }
}
