import Foundation

final class ControlServer: @unchecked Sendable {
    private let path: String
    private let handler: @MainActor ([String: String], @escaping @Sendable (String) -> Void) -> Void
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false

    /// `handler` answers through its reply callback, now or later (an eval waits on the page); the first answer counts.
    init(path: String, handler: @escaping @MainActor ([String: String], @escaping @Sendable (String) -> Void) -> Void) {
        self.path = path
        self.handler = handler
    }

    func start() {
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { NSLog("pane: control socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else {
            NSLog("pane: control socket path too long")
            close(s)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) }
        }
        guard rc == 0 else {
            NSLog("pane: control bind() failed: %d", errno)
            close(s)
            return
        }
        chmod(path, 0o600)
        guard listen(s, 16) == 0 else {
            NSLog("pane: control listen() failed: %d", errno)
            close(s)
            return
        }
        lock.lock()
        fd = s
        stopped = false
        lock.unlock()
        let t = Thread { [weak self] in self?.acceptLoop(s) }
        t.name = "pane.control"
        t.qualityOfService = .utility
        t.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let s = fd
        fd = -1
        lock.unlock()
        if s >= 0 { shutdown(s, SHUT_RDWR); close(s) }
        unlink(path)
    }

    static let replyTimeout: Double = 20

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private let ready = DispatchSemaphore(value: 0)
        private var text: String?
        func set(_ s: String) {
            lock.lock()
            defer { lock.unlock() }
            guard text == nil else { return }
            text = s
            ready.signal()
        }
        func wait(seconds: Double) -> String? {
            guard ready.wait(timeout: .now() + seconds) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return text
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(_ s: Int32) {
        while !isStopped {
            let c = accept(s, nil, nil)
            if c < 0 {
                if isStopped { return }
                switch errno {
                case EINTR, ECONNABORTED: continue
                case EMFILE, ENFILE: usleep(100_000); continue   // fd table full: back off instead of spinning
                default: NSLog("pane: control accept() failed: %d", errno); return
                }
            }
            configure(c)
            DispatchQueue.global(qos: .utility).async { [self] in handle(c) }
        }
    }

    private func handle(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(c, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.count > 8 << 20 { data.removeAll(); break }   // oversize: answer "bad request" (an eval can carry a whole page)
            if data.contains(10) { break }
        }
        if let i = data.firstIndex(of: 10) { data = data.prefix(upTo: i) }
        let reply: String
        if let msg = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            let h = handler, answer = Answer()
            DispatchQueue.main.async { MainActor.assumeIsolated { h(msg) { answer.set($0) } } }
            reply = answer.wait(seconds: Self.replyTimeout) ?? #"{"error":"timed out"}"#
        } else {
            reply = "{\"error\":\"bad request\"}"
        }
        let out = Array((reply + "\n").utf8)
        var off = 0
        while off < out.count {
            let n = out[off...].withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            off += n
        }
    }
}

enum ControlClient {
    static func run(_ args: [String]) -> Int32 {
        let env = ProcessInfo.processInfo.environment
        let path = env["PANE_SOCK"] ?? (NSHomeDirectory() + "/Library/Application Support/Workbench/pane.sock")
        let paneID = env["PANE_ID"]
        guard let cmd = args.first else { return usage() }

        if cmd == "hook" {
            guard let paneID, args.count > 1 else { return 0 }
            // Drain Claude's hook payload (unused) so its write never fails with EPIPE; Codex passes argv instead.
            if args.count == 2, isatty(0) == 0 { _ = FileHandle.standardInput.readDataToEndOfFile() }
            _ = send(["cmd": "hook", "pane": paneID, "event": args[1]], path: path)
            return 0
        }

        var msg: [String: String]
        let rest = Array(args.dropFirst())
        switch cmd {
        case "list":
            msg = ["cmd": "list"]
        case "focus":
            guard let id = rest.first else { return usage() }
            msg = ["cmd": "focus", "pane": id]
        case "split":
            let down = rest.contains("--down")
            let words = rest.filter { $0 != "--down" }
            msg = ["cmd": "split", "pane": paneID ?? "", "axis": down ? "vertical" : "horizontal"]
            if !words.isEmpty { msg["command"] = words.joined(separator: " ") }
        case "send":
            guard rest.count >= 2 else { return usage() }
            msg = ["cmd": "send", "pane": rest[0], "text": rest.dropFirst().joined(separator: " ")]
        case "open":
            guard let p = rest.first else { return usage() }
            let abs = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
            msg = ["cmd": "open", "pane": paneID ?? "", "path": (abs as NSString).standardizingPath]
        case "browse":
            // browse <url|file> [--beside <pane>] [--ratio <share of the page>]: a web pane right of the pane
            guard let target = rest.first else { return usage() }
            let url: String
            if target.contains("://") {
                url = target
            } else {
                let abs = target.hasPrefix("/") ? target : FileManager.default.currentDirectoryPath + "/" + target
                url = URL(fileURLWithPath: (abs as NSString).standardizingPath).absoluteString
            }
            msg = ["cmd": "browse", "url": url, "pane": flag("--beside", in: rest) ?? paneID ?? ""]
            if let r = flag("--ratio", in: rest) { msg["ratio"] = r }
        case "eval":
            // eval <pane> <js...>: prints {"result": <value>}
            guard rest.count >= 2 else { return usage() }
            msg = ["cmd": "eval", "pane": rest[0], "code": rest.dropFirst().joined(separator: " ")]
        case "close":
            // close <pane>: a web pane
            guard let id = rest.first else { return usage() }
            msg = ["cmd": "close", "pane": id]
        case "add":
            let p = rest.first ?? "."
            let abs = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
            msg = ["cmd": "add", "path": (abs as NSString).standardizingPath]
        case "clone":
            guard let url = rest.first else { return usage() }
            msg = ["cmd": "clone", "url": url]
            if let p = rest.dropFirst().first {
                let abs = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
                msg["path"] = (abs as NSString).standardizingPath
            }
        default:
            return usage()
        }

        guard let reply = send(msg, path: path, timeout: cmd == "eval" || cmd == "browse" ? Int(ControlServer.replyTimeout) + 5 : 2) else {
            FileHandle.standardError.write(Data("pane: Workbench is not running\n".utf8))
            return 1
        }
        if let d = reply.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           obj["error"] != nil {
            FileHandle.standardError.write(Data((reply + "\n").utf8))
            return 1
        }
        print(reply)
        return 0
    }

    private static func usage() -> Int32 {
        FileHandle.standardError.write(Data("""
        usage: pane <command>
          hook <event>
          list
          focus <pane-id>
          split [--down] [command...]
          send <pane-id> <text...>
          open <path>
          browse <url|file> [--beside <pane-id>] [--ratio <0.1-0.9>]
          eval <pane-id> <js...>
          close <pane-id>
          add [dir]
          clone <url> [dir]

        """.utf8))
        return 2
    }

    static func encode(_ msg: [String: String]) -> Data? {
        guard var d = try? JSONSerialization.data(withJSONObject: msg, options: [.sortedKeys]) else { return nil }
        d.append(10)
        return d
    }

    private static func flag(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// Connected client socket with send/receive timeouts (2 s unless an eval waits on a page), so a stalled app
    /// never stalls an agent hook.
    private static func connect(path: String, timeout: Int) -> Int32? {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        configure(s, timeout: timeout)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, len) }
        }
        guard rc == 0 else { close(s); return nil }
        return s
    }

    private static func send(_ msg: [String: String], path: String, timeout: Int = 2) -> String? {
        guard let out = encode(msg), let s = connect(path: path, timeout: timeout) else { return nil }
        defer { close(s) }
        var off = 0
        while off < out.count {
            let n = out[off...].withUnsafeBytes { write(s, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            off += n
        }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(s, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.contains(10) { break }
        }
        if let i = data.firstIndex(of: 10) { data = data.prefix(upTo: i) }
        return String(decoding: data, as: UTF8.self)
    }
}

#if DEBUG
func controlSelfCheck() {
    let msg = ["cmd": "hook", "pane": "X", "event": "stop"]
    let d = ControlClient.encode(msg)!
    assert(d.last == 10)
    let back = try! JSONSerialization.jsonObject(with: d.dropLast()) as! [String: String]
    assert(back == msg)
    let j = JiraLinks(browse: "https://kwimpos.atlassian.net/browse/", projects: ["MER"])
    assert(j.url("MER-2565")?.absoluteString == "https://kwimpos.atlassian.net/browse/MER-2565")
    assert(j.url("UTF-8") == nil && j.url("MER-2565x") == nil && j.url("xMER-1") == nil)
    assert(JiraLinks(browse: "", projects: ["MER"]).pattern == nil)
    assert(JiraLinks(browse: "x", projects: []).url("MER-1") == nil)
    assert(JiraLinks(browse: "x", projects: ["A\nkeybind = x", "MER"]).pattern == "\\b(?:MER)-[0-9]+\\b")
    assert(JiraLinks.parseProjects("mer, ops  MER,1x,a-b") == ["MER", "OPS"])
}
#endif

/// No SIGPIPE, and 2 s send/receive deadlines so a stalled peer never pins a thread or an fd.
private func configure(_ s: Int32, timeout: Int = 2) {
    var one: Int32 = 1
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}
