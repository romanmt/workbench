import AppKit

typealias PaneID = UUID

struct Launch: Codable, Equatable, Sendable {
    var command: String          // typed into the shell; rewritten at quit to the agent's resume command
    var scrollbackLimit: Int?
}

enum PaneKind: Codable, Equatable, Sendable {
    case terminal(cwd: String, launch: Launch?)
    case file(path: String)   // markdown preview, or highlighted code
    case web(url: String)     // a page an agent opened beside its terminal (`pane browse`); dropped at load

    private enum CodingKeys: String, CodingKey { case terminal, file = "markdown", web }   // saved layouts predate code files
}

struct PaneSpec: Codable, Equatable, Sendable {
    var id: PaneID
    var kind: PaneKind
}

enum Axis: String, Codable, Sendable {
    case horizontal
    case vertical
}

indirect enum SplitNode: Codable, Equatable, Sendable {
    case leaf(PaneSpec)
    case split(axis: Axis, ratio: Double, a: SplitNode, b: SplitNode)
}

extension SplitNode {
    var leaves: [PaneSpec] {
        switch self {
        case .leaf(let s): return [s]
        case .split(_, _, let a, let b): return a.leaves + b.leaves
        }
    }

    func contains(_ id: PaneID) -> Bool {
        switch self {
        case .leaf(let s): return s.id == id
        case .split(_, _, let a, let b): return a.contains(id) || b.contains(id)
        }
    }

    func replacing(_ id: PaneID, with node: SplitNode) -> SplitNode {
        switch self {
        case .leaf(let s):
            return s.id == id ? node : self
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio, a: a.replacing(id, with: node), b: b.replacing(id, with: node))
        }
    }

    func removing(_ id: PaneID) -> SplitNode? {
        switch self {
        case .leaf(let s):
            return s.id == id ? nil : self
        case .split(let axis, let ratio, let a, let b):
            guard contains(id) else { return self }
            let na = a.removing(id)
            let nb = b.removing(id)
            if let na, let nb { return .split(axis: axis, ratio: ratio, a: na, b: nb) }
            return na ?? nb
        }
    }

    func updating(_ id: PaneID, _ f: (inout PaneSpec) -> Void) -> SplitNode {
        switch self {
        case .leaf(var s):
            if s.id == id { f(&s) }
            return .leaf(s)
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio, a: a.updating(id, f), b: b.updating(id, f))
        }
    }

    func mapLeaves(_ f: (inout PaneSpec) -> Void) -> SplitNode {
        switch self {
        case .leaf(var s):
            f(&s)
            return .leaf(s)
        case .split(let axis, let ratio, let a, let b):
            return .split(axis: axis, ratio: ratio, a: a.mapLeaves(f), b: b.mapLeaves(f))
        }
    }

    /// `id` taken out and put beside `target`, sharing its space on side `edge`; unchanged if either is missing or
    /// they are the same pane.
    func moving(_ id: PaneID, to target: PaneID, _ edge: FocusDirection) -> SplitNode {
        guard id != target, let moved = leaves.first(where: { $0.id == id }), let rest = removing(id),
              let old = rest.leaves.first(where: { $0.id == target }) else { return self }
        let axis: Axis = edge == .left || edge == .right ? .horizontal : .vertical
        let first = edge == .left || edge == .up
        return rest.replacing(target, with: .split(axis: axis, ratio: 0.5, a: .leaf(first ? moved : old),
                                                   b: .leaf(first ? old : moved)))
    }

    func equalized() -> SplitNode {
        switch self {
        case .leaf: return self
        case .split(let axis, _, let a, let b):
            return .split(axis: axis, ratio: 0.5, a: a.equalized(), b: b.equalized())
        }
    }
}

struct Tab: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var root: SplitNode
    var focused: PaneID?
    var customTitle: String? = nil   // set by renaming the tab; wins over the terminal's title
}

struct Project: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var path: String
    var name: String
    var tabs: [Tab]
    var activeTab: Int
    var scratch: Bool? = nil   // temporary home-folder project: gone when its last tab closes, never restored
    var hidden: Bool? = nil    // off the Active list, shown under Hidden; its terminals and agents keep running
    var workspace: UUID? = nil // the workspace it is listed in (nil only for scratch terminals; fixed up at load)
    var todos: [Todo]? = nil   // the right sidebar's checklist
    var inspectorOpen: Bool? = nil   // the right sidebar is open while this project is shown (nil = closed)
    var inspectorTab: Int? = nil     // and shows this tab: 0 TODO (nil), 1 Files
}

struct Todo: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var text: String
    var done: Bool
}

/// A group of projects (Personal, Work…), picked in the sidebar's rail. Its icon is `image` (cropped and downscaled
/// when chosen), else `emoji`, else a monogram of the name.
struct Workspace: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var image: String? = nil       // file name in Store.workspaceImages; wins over the emoji
    var emoji: String? = nil
    var color: Int? = nil          // index into the rail's palette; nil = the id-derived default
    var lastProject: UUID? = nil   // reselected when switching back to this workspace
}

/// Every layout has at least one workspace and every non-scratch project belongs to one that exists; layouts saved
/// before workspaces get a single "Personal" holding everything. The active workspace follows the active project.
func normalizeWorkspaces(_ l: inout Layout) {
    if (l.workspaces ?? []).isEmpty { l.workspaces = [Workspace(id: UUID(), name: "Personal")] }
    let ids = Set((l.workspaces ?? []).map(\.id)), first = l.workspaces?.first?.id
    for i in l.projects.indices where l.projects[i].scratch != true && !ids.contains(l.projects[i].workspace ?? UUID()) {
        l.projects[i].workspace = first
    }
    let activeHome = l.projects.indices.contains(l.activeProject) ? l.projects[l.activeProject].workspace : nil
    if let activeHome { l.activeWorkspace = activeHome } else if !ids.contains(l.activeWorkspace ?? UUID()) { l.activeWorkspace = first }
}

/// Project indices shown in the sidebar for `workspace`'s Active (`hidden == false`) or Hidden list, in order.
/// Scratch terminals are never listed (they have their own area under the list).
func visibleProjectIndices(_ projects: [Project], hidden: Bool, workspace: UUID?) -> [Int] {
    projects.indices.filter {
        projects[$0].scratch != true && (projects[$0].hidden ?? false) == hidden && projects[$0].workspace == workspace
    }
}

/// Web panes belong to the agent that opened them, which opens its page again; a tab left empty goes too.
func dropWebPanes(_ l: inout Layout) {
    for i in l.projects.indices {
        l.projects[i].tabs = l.projects[i].tabs.compactMap { tab in
            var tab = tab
            for leaf in tab.root.leaves {
                guard case .web = leaf.kind else { continue }
                guard let rest = tab.root.removing(leaf.id) else { return nil }
                tab.root = rest
            }
            return tab
        }
    }
}

/// Indices of the scratch terminals, in order (the sidebar's bottom area).
func scratchProjectIndices(_ projects: [Project]) -> [Int] {
    projects.indices.filter { projects[$0].scratch == true }
}

/// Dragging visible row `from` to visible row `to` (`map`: visible row -> project index) moves that project to the
/// other row's position in the full list; hidden projects in between keep their places.
func reorderedProjects(_ projects: [Project], map: [Int], from: Int, to: Int) -> [Project]? {
    guard map.indices.contains(from), map.indices.contains(to) else { return nil }
    var p = projects
    p.insert(p.remove(at: map[from]), at: map[to])
    return p
}

/// Jira ticket keys of the listed projects (not a generic KEY-123 shape, which would hit UTF-8, SHA-256, ISO-8601).
/// libghostty highlights `pattern` on ⌘-hover (the `link` override) and openURL maps a click to `browse` + key.
struct JiraLinks: Codable, Equatable, Sendable {
    var browse: String
    var projects: [String]

    /// Keys are re-checked here, not only in Settings: they reach the Ghostty config from imported backups too.
    var pattern: String? {
        let keys = projects.filter { $0.range(of: "^[A-Z][A-Z0-9]*$", options: .regularExpression) != nil }
        return keys.isEmpty || browse.isEmpty ? nil : "\\b(?:" + keys.joined(separator: "|") + ")-[0-9]+\\b"
    }

    /// The browse URL if `text` is exactly one ticket key, else nil.
    func url(_ text: String) -> URL? {
        guard let pattern else { return nil }
        return text.range(of: pattern, options: .regularExpression) == text.startIndex..<text.endIndex ? URL(string: browse + text) : nil
    }

    static func parseProjects(_ s: String) -> [String] {
        var seen = Set<String>()
        return s.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { $0.uppercased() }
            .filter { $0.range(of: "^[A-Z][A-Z0-9]*$", options: .regularExpression) != nil && seen.insert($0).inserted }
    }
}

struct Layout: Codable, Equatable, Sendable {
    var projects: [Project]
    var activeProject: Int
    var sidebarVisible: Bool
    var theme: String
    var showHidden: Bool? = nil   // sidebar lists the hidden projects instead of the active ones (nil = active)
    var workspaces: [Workspace]? = nil   // never empty after load (normalizeWorkspaces)
    var activeWorkspace: UUID? = nil
    var backupRemote: String? = nil   // git remote Backup syncs to (Settings > Backup; clone in Store.directory/sync); never exported
    var showClutterFiles: Bool? = nil   // Files tab lists dotfiles and build folders (nil = hidden)
    var jira: JiraLinks? = nil   // ticket keys ⌘-click to the browse URL (Settings > Links); nil = off
    var cloneLocations: [String]? = nil   // folders New Project has cloned into, most recent first (the next clone's default)

    static let `default` = Layout(
        projects: [],
        activeProject: 0,
        sidebarVisible: true,
        theme: "oceanic-v2"
    )
}

/// A regular file's contents, read once and at most `cap` bytes; nil when missing, not a regular file, or larger
/// than `cap`, so a FIFO, device or runaway file can neither block nor exhaust memory.
func readFile(_ url: URL, cap: Int) -> Data? {
    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
          let h = try? FileHandle(forReadingFrom: url) else { return nil }
    let data = (try? h.read(upToCount: cap + 1)) ?? Data()
    return data.count > cap ? nil : data
}

@MainActor final class Store {
    nonisolated static let directory: URL = {
        #if DEBUG
        // Test isolation: a debug instance can run beside the real app without sharing its socket or layout.
        if let dir = ProcessInfo.processInfo.environment["PANE_STATE_DIR"] { return URL(fileURLWithPath: dir) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workbench")
    }()

    static let workspaceImages = directory.appendingPathComponent("workspaces")

    var layout: Layout
    var onChange: (() -> Void)?   // after every change (Backup's git sync debounces on it)
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "pane.store")

    init() {
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        let url = Store.directory.appendingPathComponent("layout.json")
        let decoded = readFile(url, cap: 16 << 20).flatMap { try? JSONDecoder().decode(Layout.self, from: $0) }
        if decoded == nil, FileManager.default.fileExists(atPath: url.path) {
            // Never overwrite a layout we failed to read; keep it for recovery.
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("bak"))
        }
        var l = decoded ?? Layout.default
        // migration: the links used to be built in; existing setups keep them (clearing in Settings stores an empty list, not nil)
        if decoded != nil && l.jira == nil {
            l.jira = JiraLinks(browse: "https://kwimpos.atlassian.net/browse/", projects: ["IN", "OPS", "MER", "ECOM", "MPOS", "PLAT", "BOP", "WS", "STOR", "MOD", "TES", "OMS", "CS", "CRISIS", "MS", "HELPDESK", "AIR", "PMI", "DS", "KIT", "BOSS", "MFA", "BIJA", "SHOP"])
        }
        let active = l.projects.indices.contains(l.activeProject) ? l.projects[l.activeProject].id : nil
        l.projects.removeAll { $0.scratch == true }
        // -1 = no project selected (every active one hidden); keep it rather than surfacing a hidden project.
        l.activeProject = l.projects.firstIndex { $0.id == active } ?? (l.activeProject < 0 || l.projects.isEmpty ? -1 : 0)
        normalizeWorkspaces(&l)
        dropWebPanes(&l)
        for i in l.projects.indices {
            let n = l.projects[i].tabs.count
            l.projects[i].activeTab = n == 0 ? 0 : min(max(l.projects[i].activeTab, 0), n - 1)
            for t in l.projects[i].tabs.indices where !(l.projects[i].tabs[t].focused.map(l.projects[i].tabs[t].root.contains) ?? false) {
                l.projects[i].tabs[t].focused = l.projects[i].tabs[t].root.leaves.first?.id
            }
        }
        layout = l
    }

    func changed() {
        onChange?()
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save(wait: false) }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func flush() { save(wait: true) }

    /// Snapshot on main, encode and write on the serial queue: debounced saves never block main; flush (quit)
    /// waits, which also drains any earlier queued write first.
    private func save(wait: Bool) {
        pending?.cancel()
        pending = nil
        let snapshot = layout
        let url = Store.directory.appendingPathComponent("layout.json")
        let write: @Sendable () -> Void = {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? enc.encode(snapshot) else { return }
            _ = try? data.write(to: url, options: .atomic)
        }
        if wait { queue.sync(execute: write) } else { queue.async(execute: write) }
    }
}

#if DEBUG
func modelSelfCheck() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let md = dir.appendingPathComponent("a.md"), empty = dir.appendingPathComponent("e.md"), fifo = dir.appendingPathComponent("f.md")
    try! Data("# hi".utf8).write(to: md); try! Data().write(to: empty); mkfifo(fifo.path, 0o600)
    let sh = Session.shell(cwd: "/tmp/x", paneEnv: ["PANE_ID": "P"], base: ["SHELL": "/bin/zsh", "ZDOTDIR": "/z", "GHOSTTY_RESOURCES_DIR": "/r/ghostty"])
    assert(sh.env["TERM"] == "xterm-ghostty" && sh.env["ZDOTDIR"] == "/r/ghostty/shell-integration/zsh" && sh.env["GHOSTTY_ZSH_ZDOTDIR"] == "/z")
    assert(sh.env["PWD"] == "/tmp/x" && sh.env["PANE_ID"] == "P" && sh.argv[0] == "/usr/bin/login")
    assert(FilePaneView.load(md.path) == "# hi" && FilePaneView.load(empty.path) == "")
    assert(FilePaneView.load(fifo.path).hasPrefix("Cannot preview"))   // must not block

    assert((try? JSONDecoder().decode(Workspace.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"W"}"#.utf8)))?.color == nil)   // old layouts decode

    // Every grammar's query compiles (queries come from resource bundles beside the binary), and highlights land.
    for ext in ["ex", "exs", "heex", "py", "js", "jsx", "ts", "tsx", "go", "rs", "rb", "java", "c", "cpp", "cs", "json", "sh",
                "html", "css", "swift", "yaml", "toml", "lua", "kt", "dockerfile"] {
        assert(Syntax.highlights("x", key: ext) != nil, "no highlight query for .\(ext)")
    }
    let ex = "defmodule A do\n  def f, do: \"s\"\nend\n"
    let spans = Syntax.highlights(ex, key: "ex") ?? []
    assert(spans.contains { $0.name.hasPrefix("keyword") && $0.range == NSRange(location: 0, length: 9) })
    assert(spans.contains { $0.name.hasPrefix("string") })
    assert(Syntax.key(for: "/a/Dockerfile") == "dockerfile" && Syntax.key(for: "/a/b.EXS") == "exs" && Syntax.key(for: "/a/b.zzz") == nil)
    assert(Syntax.key(fence: "elixir") == "ex" && Syntax.key(fence: "ts title=x") == "ts")
    let oldKind = #"{"markdown":{"path":"/m.md"}}"#   // layouts saved before code files
    assert(try! JSONDecoder().decode(PaneKind.self, from: Data(oldKind.utf8)) == .file(path: "/m.md"))

    func leaf() -> PaneSpec { PaneSpec(id: UUID(), kind: .file(path: "/x")) }
    let p1 = leaf(), p2 = leaf(), p3 = leaf()
    let tree = SplitNode.split(axis: .horizontal, ratio: 0.3, a: .leaf(p1),
                               b: .split(axis: .vertical, ratio: 0.7, a: .leaf(p2), b: .leaf(p3)))
    assert(tree.removing(p2.id)?.leaves.map(\.id) == [p1.id, p3.id])
    assert(tree.removing(p1.id) == .split(axis: .vertical, ratio: 0.7, a: .leaf(p2), b: .leaf(p3)))
    assert(SplitNode.leaf(p1).removing(p1.id) == nil)
    let p4 = leaf()
    let rep = tree.replacing(p2.id, with: .leaf(p4))
    assert(rep.leaves.map(\.id) == [p1.id, p4.id, p3.id])
    assert(!rep.contains(p2.id))
    func ratios(_ n: SplitNode) -> [Double] {
        if case .split(_, let r, let a, let b) = n { return [r] + ratios(a) + ratios(b) }
        return []
    }
    assert(ratios(tree.equalized()) == [0.5, 0.5])
    // hidden projects: absent in an old layout.json = active; reorder within the filtered list
    let oldProject = "{\"id\":\"\(UUID().uuidString)\",\"path\":\"/a\",\"name\":\"a\",\"tabs\":[],\"activeTab\":0}"
    assert(try! JSONDecoder().decode(Project.self, from: Data(oldProject.utf8)).hidden == nil)
    func proj(_ n: String, _ h: Bool?) -> Project { Project(id: UUID(), path: "/" + n, name: n, tabs: [], activeTab: 0, hidden: h) }
    let projs = [proj("A", nil), proj("h1", true), proj("B", false), proj("h2", true), proj("C", nil)]
    assert(visibleProjectIndices(projs, hidden: false, workspace: nil) == [0, 2, 4] && visibleProjectIndices(projs, hidden: true, workspace: nil) == [1, 3])
    let act = [0, 2, 4]
    assert(reorderedProjects(projs, map: act, from: 0, to: 2)?.map(\.name) == ["h1", "B", "h2", "C", "A"])
    assert(reorderedProjects(projs, map: act, from: 2, to: 0)?.map(\.name) == ["C", "A", "h1", "B", "h2"])
    assert(reorderedProjects(projs, map: act, from: 0, to: 3) == nil)
    // scratch terminals: in neither list, found separately
    var scr = proj("S", nil); scr.scratch = true
    let withScratch = projs + [scr]
    assert(visibleProjectIndices(withScratch, hidden: false, workspace: nil) == [0, 2, 4] && visibleProjectIndices(withScratch, hidden: true, workspace: nil) == [1, 3])
    // workspaces: an old layout gets one holding every project; strays join the first; active follows the project
    var wl = Layout(projects: projs + [scr], activeProject: 2, sidebarVisible: true, theme: "t")
    normalizeWorkspaces(&wl)
    let home = wl.workspaces![0].id
    assert(wl.workspaces!.count == 1 && wl.activeWorkspace == home && wl.projects.last!.workspace == nil)
    assert(wl.projects.dropLast().allSatisfy { $0.workspace == home })
    let kwi = Workspace(id: UUID(), name: "KWI")
    wl.workspaces!.append(kwi); wl.projects[2].workspace = kwi.id; wl.projects[0].workspace = UUID()
    normalizeWorkspaces(&wl)
    assert(wl.activeWorkspace == kwi.id && wl.projects[0].workspace == home)
    assert(visibleProjectIndices(wl.projects, hidden: false, workspace: kwi.id) == [2])
    assert(monogram("KWI") == "KWI" && monogram("Personal") == "P" && monogram("side-projects") == "SP" && monogram("") == "?")
    // a chosen picture is stored center-cropped and downscaled
    let big = NSImage(size: NSSize(width: 1200, height: 800), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
    let src = dir.appendingPathComponent("big.png")
    try! NSBitmapImageRep(data: big.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: src)
    let icon = NSBitmapImageRep(data: workspaceIconPNG(src)!)!
    assert(icon.pixelsWide == 128 && icon.pixelsHigh == 128)
    assert(scratchProjectIndices(withScratch) == [5] && scratchProjectIndices(projs).isEmpty)
    // p2 over p3, drag p3 to p2's right: they become side by side
    assert(tree.moving(p3.id, to: p2.id, .right) == .split(axis: .horizontal, ratio: 0.3, a: .leaf(p1),
                                                            b: .split(axis: .horizontal, ratio: 0.5, a: .leaf(p2), b: .leaf(p3))))
    assert(tree.moving(p1.id, to: p3.id, .up) == .split(axis: .vertical, ratio: 0.7, a: .leaf(p2),
                                                         b: .split(axis: .vertical, ratio: 0.5, a: .leaf(p1), b: .leaf(p3))))
    assert(tree.moving(p1.id, to: p1.id, .left) == tree && tree.moving(p1.id, to: UUID(), .left) == tree)
    let mapped = tree.mapLeaves { $0.kind = .file(path: "/y") }
    assert(mapped.leaves.map(\.id) == tree.leaves.map(\.id) && mapped.leaves.allSatisfy { $0.kind == .file(path: "/y") })
    // web panes are not restored: the pane goes, and a tab holding only one goes with it
    let web = PaneSpec(id: UUID(), kind: .web(url: "file:///x.html"))
    var withWeb = Layout(
        projects: [Project(id: UUID(), path: "/p", name: "p", tabs: [
            Tab(id: UUID(), title: "a", root: .split(axis: .horizontal, ratio: 0.6, a: .leaf(p1), b: .leaf(web)), focused: web.id),
            Tab(id: UUID(), title: "b", root: .leaf(PaneSpec(id: UUID(), kind: .web(url: "https://x"))), focused: nil),
        ], activeTab: 0)],
        activeProject: 0, sidebarVisible: true, theme: "t")
    dropWebPanes(&withWeb)
    assert(withWeb.projects[0].tabs.count == 1 && withWeb.projects[0].tabs[0].root == .leaf(p1))
    let old = #"{"command":"c","resume":"r {id}","agent":"claude","sessionID":"S"}"#
    assert(try! JSONDecoder().decode(Launch.self, from: Data(old.utf8)) == Launch(command: "c", scrollbackLimit: nil))
    let layout = Layout(
        projects: [Project(id: UUID(), path: "/p", name: "p",
                           tabs: [Tab(id: UUID(), title: "t", root: tree, focused: p1.id)], activeTab: 0)],
        activeProject: 0, sidebarVisible: true, theme: "t")
    let withPresets = #"{"projects":[],"activeProject":0,"sidebarVisible":true,"theme":"t","presets":[{"key":1,"name":"x","command":"c"}]}"#
    assert(try! JSONDecoder().decode(Layout.self, from: Data(withPresets.utf8)).theme == "t")   // old layouts keep a presets key
    let oldTab = #"{"id":"\#(UUID().uuidString)","title":"t","root":{"leaf":{"_0":{"id":"\#(p1.id.uuidString)","kind":{"markdown":{"path":"/x"}}}}}}"#
    assert(try! JSONDecoder().decode(Tab.self, from: Data(oldTab.utf8)).customTitle == nil)
    let data = try! JSONEncoder().encode(layout)
    assert(try! JSONDecoder().decode(Layout.self, from: data) == layout)
}
#endif
