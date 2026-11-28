import SwiftUI
import Network

/// Apple TV has no Files app and no share sheet, so a backup travels over the home network: while
/// this section is on screen the Apple TV serves a small page, and a phone that scans the QR code
/// can save the backup or send one back to restore.
struct BackupTransferSection: View {
    @Binding var message: String?
    @Environment(Library.self) private var library
    @Environment(SourceMemory.self) private var memory
    @Environment(ListsStore.self) private var lists
    @State private var server = BackupServer()
    @State private var pending: Data?

    var body: some View {
        Section {
            if let address = server.address {
                HStack(alignment: .center, spacing: 40) {
                    if let image = QRCodeSheet.code(for: address.absoluteString) {
                        Image(uiImage: image).interpolation(.none).resizable()
                            .frame(width: 280, height: 280)
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scan with your phone").font(.headline)
                        Text("Your phone opens a page on this Apple TV where you can save a backup or send one back to restore. It has to be on the same Wi-Fi.")
                            .font(.callout).foregroundStyle(Theme.secondaryText)
                        Text(address.absoluteString).font(.callout.monospaced())
                    }
                }
                .padding(.vertical, 12)
            } else if let error = server.error {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(Theme.warning)
            } else {
                ProgressView()
            }
        } footer: {
            Text("Saves My List, your history and resume points, what \(AppConfig.name) learned about sources, addons and settings. Your debrid key and Trakt sign-in aren't included; enter them again after restoring. Apple TV may clear an app's data when it runs short of space, so keep a backup.")
        }
        .onAppear {
            server.backup = { [library, memory, lists] in Backup.data(library: library, memory: memory, lists: lists) }
            server.received = { data in pending = data }
            server.start()
        }
        .onDisappear { server.stop() }
        .confirmationDialog("Replace this Apple TV's library and settings with the backup from your phone?",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                guard let data = pending else { return }
                do {
                    try Backup.restore(data, library: library, memory: memory, lists: lists)
                    message = "Restored. Close and reopen \(AppConfig.name) for the restored settings to take effect."
                } catch {
                    message = "That file isn't a \(AppConfig.name) backup."
                }
            }
        }
    }
}

/// A minimal HTTP server on the local network: `GET /` is the page, `GET /backup.json` the backup,
/// `POST /restore` a backup to restore. Runs only while the backup page is open.
@MainActor
@Observable
final class BackupServer {
    private(set) var address: URL?
    private(set) var error: String?
    @ObservationIgnored var backup: (@MainActor () -> Data?)?
    @ObservationIgnored var received: (@MainActor (Data) -> Void)?
    @ObservationIgnored private var listener: NWListener?
    private static let limit = 50 * 1024 * 1024

    func start() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.update(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            self.error = "Couldn't open the backup page: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        address = nil
    }

    private func update(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            if let ip = Self.localAddress() {
                address = URL(string: "http://\(ip):\(port)/")
                error = nil
            } else {
                error = "This Apple TV isn't on a network."
            }
        case let .failed(failure):
            error = "Couldn't open the backup page: \(failure.localizedDescription)"
            address = nil
        default: break
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, buffer: Data())
    }

    /// Reads until the headers and the whole body (by Content-Length) have arrived.
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, done, failure in
            Task { @MainActor in
                guard let self else { return }
                var data = buffer
                if let chunk { data.append(chunk) }
                if failure != nil || data.count > Self.limit { connection.cancel(); return }
                if let request = Request(data) {
                    self.respond(to: request, on: connection)
                } else if done {
                    connection.cancel()
                } else {
                    self.read(connection, buffer: data)
                }
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/"):
            send(connection, status: "200 OK", type: "text/html; charset=utf-8", body: Data(Self.page.utf8))
        case ("GET", "/backup.json"):
            guard let data = backup?() else {
                send(connection, status: "500 Internal Server Error", type: "text/plain", body: Data("No backup".utf8)); return
            }
            let day = Date().formatted(.iso8601.year().month().day())
            send(connection, status: "200 OK", type: "application/json", body: data,
                 extra: "Content-Disposition: attachment; filename=\"\(AppConfig.name) Backup \(day).json\"\r\n")
        case ("POST", "/restore"):
            received?(request.body)
            send(connection, status: "200 OK", type: "text/plain; charset=utf-8",
                 body: Data("Sent. Confirm the restore on the TV.".utf8))
        default:
            send(connection, status: "404 Not Found", type: "text/plain", body: Data("Not found".utf8))
        }
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data, extra: String = "") {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private struct Request {
        let method: String
        let path: String
        let body: Data

        /// Nil until the headers and the full body are in.
        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            guard parts.count >= 2 else { return nil }
            let length = lines.dropFirst()
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            let body = data[end.upperBound...]
            guard body.count >= length else { return nil }
            method = String(parts[0])
            path = String(parts[1].split(separator: "?").first ?? "/")
            self.body = Data(body.prefix(length))
        }
    }

    /// The Apple TV's own IPv4 address on Wi-Fi or Ethernet.
    private static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [String: String] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found[String(cString: entry.ifa_name)] = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return found["en0"] ?? found["en1"] ?? found.values.sorted().first
    }

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>\(AppConfig.name) backup</title>
    <style>body{font:17px -apple-system,system-ui,sans-serif;background:#0d0b1a;color:#fff;margin:0;padding:28px;max-width:520px}
    a,button{display:block;width:100%;box-sizing:border-box;margin:14px 0;padding:16px;border-radius:14px;border:0;font:600 17px -apple-system,system-ui;
    text-align:center;text-decoration:none;background:#f46ba8;color:#fff}button.alt{background:#2a2540}p{color:#b8b3cc}#s{min-height:1.4em}</style></head>
    <body><h1>\(AppConfig.name) on Apple TV</h1>
    <p>Save a backup of My List, history and settings from the TV, or send one back to restore it there.</p>
    <a href="/backup.json" download>Save Backup</a>
    <input id="f" type="file" accept="application/json,.json" hidden>
    <button class="alt" onclick="document.getElementById('f').click()">Restore a Backup…</button>
    <p id="s"></p>
    <script>
    document.getElementById('f').onchange=async e=>{const file=e.target.files[0];if(!file)return;const s=document.getElementById('s');
    s.textContent='Sending…';try{const r=await fetch('/restore',{method:'POST',body:await file.arrayBuffer()});s.textContent=await r.text()}
    catch(x){s.textContent='Couldn\\'t reach the Apple TV. Is the backup page still open on it?'}};
    </script></body></html>
    """
}
