import AppKit
import os

struct BackupError: Error, Sendable { let message: String }

extension Notification.Name {
    /// Posted by BackupSync when `status` changes.
    static let backupStatusChanged = Notification.Name("WorkbenchBackupStatusChanged")
}

/// Everything that makes the app yours as one JSON file: the layout (projects and their order, tabs and splits,
/// workspaces, theme), user themes, workspace images and the Ghostty config.
struct Backup: Codable, Sendable {
    var version: Int
    var exported: Date
    var machine: String?           // the Mac that wrote it (Backup.thisMachine); nil in older files
    var layout: Layout
    var themes: [String: String]   // file name in Theme.userDirectory -> contents
    var images: [String: Data]     // file name in Store.workspaceImages -> bytes, base64 in JSON
    var ghosttyConfig: String?     // ~/.config/ghostty/config, when it exists

    static let currentVersion = 1
    static func fileName(for machine: String) -> String { "workbench-\(machine).json" }   // each Mac syncs its own file, so two Macs never conflict
    static let maxSize = 64 << 20   // one cap for every backup written or read (base64 images included)
    /// This Mac's name as a file-name-safe word: "Jacob's MacBook Pro (2)" -> Jacob-s-MacBook-Pro-2.
    nonisolated static let thisMachine: String = {
        let n = (Host.current().localizedName ?? "").split { !($0.isLetter || $0.isNumber) }.joined(separator: "-")
        return n.isEmpty ? "Mac" : n
    }()
    nonisolated static let ghosttyConfigURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty/config")

    @MainActor static func current(_ layout: Layout) throws -> Backup {
        var l = layout
        let active = l.projects.indices.contains(l.activeProject) ? l.projects[l.activeProject].id : nil
        l.projects.removeAll { $0.scratch == true }
        l.activeProject = l.projects.firstIndex { $0.id == active } ?? (l.projects.isEmpty ? -1 : 0)
        l.backupRemote = nil
        var themes: [String: String] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: Theme.userDirectory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let d = readFile(f, cap: 1 << 20), let s = String(data: d, encoding: .utf8) else {
                throw BackupError(message: "Couldn't include the theme \(f.lastPathComponent): it is unreadable, not UTF-8, or over 1 MB.")
            }
            themes[f.lastPathComponent] = s
        }
        var images: [String: Data] = [:]
        for name in (l.workspaces ?? []).compactMap(\.image) {
            let url = Store.workspaceImages.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let d = readFile(url, cap: 16 << 20) else {
                throw BackupError(message: "Couldn't include the workspace image \(name): it is unreadable or over 16 MB.")
            }
            images[name] = d
        }
        var ghostty: String?
        if FileManager.default.fileExists(atPath: ghosttyConfigURL.path) {
            guard let d = readFile(ghosttyConfigURL, cap: 1 << 20), let s = String(data: d, encoding: .utf8) else {
                throw BackupError(message: "Couldn't include ~/.config/ghostty/config: it is unreadable, not UTF-8, or over 1 MB.")
            }
            ghostty = s
        }
        return Backup(version: currentVersion, exported: Date(), machine: thisMachine, layout: l, themes: themes, images: images, ghosttyConfig: ghostty)
    }

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data: Data
        do { data = try enc.encode(self) } catch {
            throw BackupError(message: "Couldn't encode the backup (\(error.localizedDescription)).")
        }
        if data.count > Backup.maxSize {
            throw BackupError(message: "The backup is over 64 MB (workspace images count toward it). Use smaller workspace images.")
        }
        return data
    }

    /// What git sync writes: the setup without what changes as you work (selection, focus, terminal titles, export time), so a commit means the setup itself changed.
    var forSync: Backup {
        var b = self
        b.exported = Date(timeIntervalSince1970: 0)
        b.layout.activeProject = b.layout.projects.isEmpty ? -1 : 0
        b.layout.activeWorkspace = nil
        for p in b.layout.projects.indices {
            b.layout.projects[p].activeTab = 0
            for t in b.layout.projects[p].tabs.indices {
                b.layout.projects[p].tabs[t].focused = nil
                b.layout.projects[p].tabs[t].title = ""
                // Resume ids change every agent turn and name sessions on this Mac: syncing them is a commit per turn.
                b.layout.projects[p].tabs[t].root = b.layout.projects[p].tabs[t].root.mapLeaves { s in
                    if case let .terminal(cwd, _) = s.kind { s.kind = .terminal(cwd: cwd, launch: nil) }
                }
            }
        }
        for w in (b.layout.workspaces ?? []).indices { b.layout.workspaces?[w].lastProject = nil }
        return b
    }

    static func decode(_ data: Data) throws -> Backup {
        guard data.count <= maxSize else { throw BackupError(message: "The backup is over 64 MB.") }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let b: Backup
        do { b = try dec.decode(Backup.self, from: data) } catch {
            throw BackupError(message: "This isn't a Workbench backup (\(error.localizedDescription))")
        }
        if b.version > currentVersion {
            throw BackupError(message: "This backup is from a newer Workbench (format \(b.version)). Update Workbench to restore it.")
        }
        func valid(_ k: String) -> Bool { !k.isEmpty && !k.hasPrefix(".") && !k.contains("/") && !k.contains(":") && k.utf8.count <= 255 }
        for k in b.themes.keys where !valid(k) || !k.hasSuffix(".json") {
            throw BackupError(message: "The backup contains an invalid file name: \(k)")
        }
        for k in Array(b.images.keys) + (b.layout.workspaces ?? []).compactMap(\.image) where !valid(k) {   // image names are paths under Store.workspaceImages
            throw BackupError(message: "The backup contains an invalid file name: \(k)")
        }
        return b
    }

    var missingProjects: [Project] {
        layout.projects.filter {
            var isDir: ObjCBool = false
            return $0.scratch != true && !(FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue)
        }
    }

    mutating func relocate(project id: UUID, to path: String) {
        guard let i = layout.projects.firstIndex(where: { $0.id == id }) else { return }
        let old = layout.projects[i].path
        layout.projects[i].path = path
        func moved(_ v: String) -> String { v == old || v.hasPrefix(old + "/") ? path + v.dropFirst(old.count) : v }
        for t in layout.projects[i].tabs.indices {
            layout.projects[i].tabs[t].root = layout.projects[i].tabs[t].root.mapLeaves { s in
                switch s.kind {
                case .terminal(let cwd, let launch): s.kind = .terminal(cwd: moved(cwd), launch: launch)
                case .file(let p): s.kind = .file(path: moved(p))
                case .web: break
                }
            }
        }
    }

    mutating func remove(project id: UUID) {
        let active = layout.projects.indices.contains(layout.activeProject) ? layout.projects[layout.activeProject].id : nil
        layout.projects.removeAll { $0.id == id }
        layout.activeProject = layout.projects.firstIndex { $0.id == active } ?? (layout.projects.isEmpty ? -1 : 0)
        for i in (layout.workspaces ?? []).indices where layout.workspaces?[i].lastProject == id { layout.workspaces?[i].lastProject = nil }
    }

    /// The current setup, saved before an import replaces it.
    @MainActor static func saveCurrent(_ layout: Layout) throws -> URL {
        let dir = Store.directory.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("workbench-\(f.string(from: Date())).json")
        try current(layout).encoded().write(to: url, options: .atomic)
        return url
    }

    /// Writes this backup over the app's state (called at quit, after the old layout's final save); themes and
    /// images are added or overwritten, never deleted; layout.json keeps this Mac's `backupRemote`.
    @MainActor func install(backupRemote: String?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Theme.userDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: Store.workspaceImages, withIntermediateDirectories: true)
        for (name, text) in themes { try Data(text.utf8).write(to: Theme.userDirectory.appendingPathComponent(name), options: .atomic) }
        for (name, data) in images { try data.write(to: Store.workspaceImages.appendingPathComponent(name), options: .atomic) }
        if let ghosttyConfig {
            try fm.createDirectory(at: Backup.ghosttyConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(ghosttyConfig.utf8).write(to: Backup.ghosttyConfigURL, options: .atomic)
        }
        var l = layout
        l.backupRemote = backupRemote
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(l).write(to: Store.directory.appendingPathComponent("layout.json"), options: .atomic)
    }
}

/// Git sync into a clone Workbench owns (Store.directory/sync), so it never touches the user's other repositories: at most every 10 minutes (and at quit) it writes this Mac's file, commits it if it changed, rebases onto the remote and pushes. The user's own git and credentials.
@MainActor final class BackupSync {
    static let shared = BackupSync()
    nonisolated static let clone = Store.directory.appendingPathComponent("sync")
    private(set) var status = ""   // shown in Settings > Backup
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "workbench.backup-sync")   // serial: syncs and fetches never overlap
    private let generation = OSAllocatedUnfairLock(initialState: 0)   // bumped by stop(); queued work from an older generation does nothing

    private func setStatus(_ s: String) {
        status = s
        NotificationCenter.default.post(name: .backupStatusChanged, object: nil)
    }

    func connect(remote: String, completion: @escaping @MainActor @Sendable (BackupError?) -> Void) {
        stop()
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if remote.isEmpty { completion(BackupError(message: "Enter a git remote URL.")); return }
        queue.async {
            try? FileManager.default.removeItem(at: BackupSync.clone)
            let r = BackupSync.git(Store.directory.path, ["clone", "-q", "--", remote, BackupSync.clone.path])
            let err = r.status != 0 ? BackupError(message: "Couldn't clone \(remote): \(r.message)") : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(err) } }
        }
    }

    func scheduleSync(_ store: Store) {
        guard store.layout.backupRemote != nil, pending == nil else { return }   // a waiting sync picks this change up too
        let item = DispatchWorkItem { [weak self, weak store] in
            MainActor.assumeIsolated { if let store { self?.syncNow(store) } }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: item)   // at most one commit per 10 minutes; quit flushes
    }

    func syncNow(_ store: Store) { start(store, wait: false) }

    /// At quit: runs a sync that was waiting for its debounce, giving git at most 5 s.
    func flush(_ store: Store) {
        guard pending != nil else { return }
        start(store, wait: true)
    }

    /// Stops syncing: drops the waiting sync, and queued work sees a newer generation and does nothing.
    func stop() {
        generation.withLock { $0 += 1 }
        pending?.cancel()
        pending = nil
        setStatus("")
    }

    private func start(_ store: Store, wait: Bool) {
        pending?.cancel()
        pending = nil
        guard store.layout.backupRemote != nil else { return }
        let data: Data
        do { data = try Backup.current(store.layout).forSync.encoded() } catch {
            setStatus("Sync failed: \((error as? BackupError)?.message ?? error.localizedDescription)")
            return
        }
        let gen = generation.withLock { $0 }, lock = generation
        let done = DispatchSemaphore(value: 0)
        queue.async {
            let result = BackupSync.run(data, gen: gen, lock: lock)
            if let result { DispatchQueue.main.async { MainActor.assumeIsolated { BackupSync.shared.setStatus(result) } } }
            done.signal()
        }
        if wait { _ = done.wait(timeout: .now() + 5) }
    }

    /// nil = stopped meanwhile.
    nonisolated private static func run(_ data: Data, gen: Int, lock: OSAllocatedUnfairLock<Int>) -> String? {
        func live() -> Bool { lock.withLock { $0 } == gen }
        guard live() else { return nil }
        let repo = clone.path, name = Backup.fileName(for: Backup.thisMachine)
        if !FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git").path) {
            return "Sync failed: not connected. Choose Connect… again."
        }
        do { try data.write(to: clone.appendingPathComponent(name), options: .atomic) } catch {
            return "Sync failed: \(error.localizedDescription)"
        }
        let add = git(repo, ["add", "--", name])
        if add.status != 0 { return "Sync failed: \(add.message)" }
        if git(repo, ["diff", "--cached", "--quiet", "--", name]).status == 1 {
            let c = git(repo, ["commit", "-q", "-m", "Workbench backup (\(Backup.thisMachine))", "--", name])
            if c.status != 0 { return "Sync failed: \(c.message)" }
        }
        guard live() else { return nil }
        let f = git(repo, ["fetch", "-q"])
        if f.status != 0 { return "Sync failed: \(f.message)" }
        let upstream = git(repo, ["rev-parse", "-q", "--verify", "@{u}"]).status == 0
        if upstream {
            let r = git(repo, ["rebase", "-q", "@{u}"])
            if r.status != 0 {
                _ = git(repo, ["rebase", "--abort"])
                return "Sync failed: \(r.message)"
            }
        }
        let ahead = upstream ? Int(git(repo, ["rev-list", "--count", "@{u}..HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 1
        guard live() else { return nil }
        if ahead > 0 {
            let p = git(repo, ["push", "-q", "-u", "origin", "HEAD"])
            if p.status != 0 { return "Sync failed: \(p.message)" }
        }
        return "Synced at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
    }

    func fetchBackups(completion: @escaping @MainActor @Sendable (Result<[Backup], BackupError>) -> Void) {
        queue.async {
            let result = BackupSync.fetchAll()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    nonisolated private static func fetchAll() -> Result<[Backup], BackupError> {
        let repo = clone.path
        guard FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git").path) else {
            return .failure(BackupError(message: "Not connected to a repository."))
        }
        let f = git(repo, ["fetch", "-q"])
        if f.status != 0 { return .failure(BackupError(message: "git fetch failed: \(f.message)")) }
        if git(repo, ["rev-parse", "-q", "--verify", "@{u}"]).status == 0 {
            let r = git(repo, ["rebase", "-q", "@{u}"])
            if r.status != 0 {
                _ = git(repo, ["rebase", "--abort"])
                return .failure(BackupError(message: "Couldn't update the sync copy: \(r.message)"))
            }
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: clone, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("workbench-") && $0.lastPathComponent.hasSuffix(".json") }
        var found: [Backup] = []
        for url in files {
            if let d = readFile(url, cap: Backup.maxSize), let b = try? Backup.decode(d) { found.append(b) }
        }
        if found.isEmpty && !files.isEmpty { return .failure(BackupError(message: "The repository's backups couldn't be read.")) }
        found.sort {
            let a = $0.machine == Backup.thisMachine, b = $1.machine == Backup.thisMachine
            return a != b ? a : ($0.machine ?? "") < ($1.machine ?? "")
        }
        return .success(found)
    }

    nonisolated private static func git(_ dir: String, _ args: [String]) -> (status: Int32, out: String, message: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }   // fail instead of waiting on a password prompt nobody sees
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        // ponytail: sequential reads; git's stderr here is a few lines
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return (p.terminationStatus, stdout, line ?? "git \(args[0]) exited with \(p.terminationStatus)")
    }
}

#if DEBUG
@MainActor func backupSelfCheck() {
    let leafA = PaneSpec(id: UUID(), kind: .terminal(cwd: "/nonexistent-wb-a/src", launch: nil))
    let leafB = PaneSpec(id: UUID(), kind: .file(path: "/nonexistent-wb-a/README.md"))
    let leafC = PaneSpec(id: UUID(), kind: .terminal(cwd: "/nonexistent-wb-ab", launch: nil))
    let tab = Tab(id: UUID(), title: "t", root: .split(axis: .horizontal, ratio: 0.5, a: .leaf(leafA),
                  b: .split(axis: .vertical, ratio: 0.5, a: .leaf(leafB), b: .leaf(leafC))), focused: nil)
    let p0 = Project(id: UUID(), path: "/nonexistent-wb-a", name: "a", tabs: [tab], activeTab: 0)
    let p1 = Project(id: UUID(), path: NSTemporaryDirectory(), name: "b", tabs: [], activeTab: 0)
    var p2 = Project(id: UUID(), path: "/tmp", name: "c", tabs: [], activeTab: 0)
    p2.scratch = true
    var l = Layout(projects: [p0, p1, p2], activeProject: 1, sidebarVisible: true, theme: "x")
    l.backupRemote = "/r"
    let b = Backup(version: 1, exported: Date(), machine: nil, layout: l, themes: [:], images: [:], ghosttyConfig: nil)
    assert(b.missingProjects.map(\.id) == [p0.id])
    assert((try! Backup.decode(try! b.encoded())).layout == b.layout)
    var bad = b
    bad.version = 99
    assert((try? Backup.decode(try! bad.encoded())) == nil)
    bad = b
    bad.themes = ["../x.json": "{}"]
    assert((try? Backup.decode(try! bad.encoded())) == nil)
    bad = b
    bad.images = [".hidden": Data()]
    assert((try? Backup.decode(try! bad.encoded())) == nil)
    bad = b
    bad.layout.workspaces = [Workspace(id: UUID(), name: "W", image: "../../.ssh/id_rsa")]
    assert((try? Backup.decode(try! bad.encoded())) == nil)

    var r = b
    r.relocate(project: p0.id, to: "/new")
    assert(r.layout.projects[0].path == "/new")
    assert(r.layout.projects[0].tabs[0].root.leaves.map(\.kind) ==
           [.terminal(cwd: "/new/src", launch: nil), .file(path: "/new/README.md"), .terminal(cwd: "/nonexistent-wb-ab", launch: nil)])

    var d = b
    d.layout.workspaces = [Workspace(id: UUID(), name: "W", lastProject: p0.id)]
    d.remove(project: p0.id)
    assert(d.layout.projects.count == 2 && d.layout.projects[d.layout.activeProject].id == p1.id)
    assert(d.layout.workspaces?[0].lastProject == nil)

    let c = try! Backup.current(l)
    assert(c.layout.projects.count == 2 && c.layout.projects[c.layout.activeProject].id == p1.id)
    assert(c.layout.backupRemote == nil)
    assert(Backup.fileName(for: "M") == "workbench-M.json")
    assert(!Backup.thisMachine.isEmpty && !Backup.thisMachine.contains("/") && !Backup.thisMachine.contains("--") && !Backup.thisMachine.hasSuffix("-"))
    bad = b
    bad.themes = [String(repeating: "a", count: 300) + ".json": "{}"]
    assert((try? Backup.decode(try! bad.encoded())) == nil)
    let s = b.forSync
    assert(s.exported == Date(timeIntervalSince1970: 0))
    assert(s.layout.projects[0].tabs[0].title == "")
    assert(s.layout.projects[0].tabs[0].focused == nil)
    assert(s.layout.activeWorkspace == nil)
    var bl = b
    bl.layout.projects[0].tabs[0].root = .leaf(PaneSpec(id: leafA.id, kind: .terminal(cwd: "/x", launch: Launch(command: "claude --resume 1"))))
    assert(bl.forSync.layout.projects[0].tabs[0].root == .leaf(PaneSpec(id: leafA.id, kind: .terminal(cwd: "/x", launch: nil))))
    var bf = b
    bf.layout.projects[0].tabs[0].focused = leafA.id
    assert((try! bf.forSync.encoded()) == (try! { var x = bf; x.layout.projects[0].tabs[0].focused = leafB.id; x.layout.activeProject = 0; return x }().forSync.encoded()))
}
#endif
