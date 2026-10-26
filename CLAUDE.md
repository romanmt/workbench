# Workbench

Native macOS terminal IDE for running many Claude Code / Codex sessions. Swift 6 + AppKit + GhosttyKit (libghostty, our fork `jacobgreenberg/ghostty` branch `workbench` (based on cmux `manaflow-ai/ghostty@cb1ef70`), built from source by `scripts/ghosttykit.sh` at its pinned SHA). Single SwiftPM executable target `Workbench`, all sources in `Sources/Workbench/`. Reference Ghostty sources (read-only) are in `vendor/ghostty-src/macos/Sources/Ghostty/`; the C API is `vendor/ghostty-src/include/ghostty.h`.

Build: `swift build -c release`, then `scripts/bundle.sh` → `build.noindex/Workbench.app`. Run: `open build.noindex/Workbench.app`.

E2E: `scripts/bundle.sh --debug` (→ `build.noindex/Workbench-debug.app`; the control socket's test harness commands and `PANE_STATE_DIR` are debug only), then `python3 -I scripts/e2e/clone.py` (isolated state dir, local git server; `--keep`, `-k <name>`) and `python3 -I scripts/e2e/web.py` (web panes: browse, eval, close, not restored).

Rules: AppKit only (no SwiftUI). macOS 27+. Chrome is Liquid Glass (NSGlassEffectView panels/capsules, `HandButton.glass` round buttons) floating over the solid theme background; never put glass over a terminal surface except transient overlays (find bar), since glass over changing content recomposites every frame. No polling timers. Every C callback is a nonisolated `@convention(c)` function that copies data into owned Swift values and hops to main with `DispatchQueue.main.async`. Never touch a SurfaceView's `wantsLayer`/`layer` before `ghostty_surface_new`. Import GhosttyKit as `@preconcurrency import GhosttyKit`.

## Contract (cross-file interfaces — keep exact)

```swift
// Model.swift
typealias PaneID = UUID
struct Launch: Codable, Equatable, Sendable {
    var command: String          // typed into the shell as initial input; rewritten at quit to the running agent's resume command
    var scrollbackLimit: Int?    // bytes; nil = global default
}
enum PaneKind: Codable, Equatable, Sendable { case terminal(cwd: String, launch: Launch?), file(path: String), web(url: String) }   // file: markdown preview or highlighted code; coded as "markdown" for old layouts. web: a page an agent opened (`pane browse`), dropped at load by dropWebPanes (with a tab it leaves empty)
struct PaneSpec: Codable, Equatable, Sendable { var id: PaneID; var kind: PaneKind }
enum Axis: String, Codable, Sendable { case horizontal /* a | b, ⌘D */, vertical /* a over b, ⇧⌘D */ }
indirect enum SplitNode: Codable, Equatable, Sendable {
    case leaf(PaneSpec)
    case split(axis: Axis, ratio: Double, a: SplitNode, b: SplitNode)
}
extension SplitNode {
    var leaves: [PaneSpec]                                        // depth-first, a before b
    func contains(_ id: PaneID) -> Bool
    func replacing(_ id: PaneID, with node: SplitNode) -> SplitNode
    func removing(_ id: PaneID) -> SplitNode?                      // nil if tree becomes empty; parent split collapses to sibling
    func updating(_ id: PaneID, _ f: (inout PaneSpec) -> Void) -> SplitNode
    func mapLeaves(_ f: (inout PaneSpec) -> Void) -> SplitNode    // f applied to every leaf
    func equalized() -> SplitNode                                  // every ratio = 0.5
    func moving(_ id: PaneID, to target: PaneID, _ edge: FocusDirection) -> SplitNode   // id re-split beside target on edge; self if same/missing
}
struct Tab: Codable, Identifiable, Equatable, Sendable { var id: UUID; var title: String; var root: SplitNode; var focused: PaneID?; var customTitle: String? = nil /* user rename; wins over the terminal title */ }
struct Project: Codable, Identifiable, Equatable, Sendable { var id: UUID; var path: String; var name: String; var tabs: [Tab]; var activeTab: Int; var scratch: Bool? = nil /* ⇧⌘N scratch terminal in ~ (reused: each press adds a tab): never listed as a project; the toolbar's terminal button (beside Add Project, badged with the scratch tab count) goes to it, or adds a tab when it is already shown; dropped when its last tab closes and at load */; var hidden: Bool? = nil /* off the Active list, listed under Hidden; terminals and agents keep running; nil/absent = active */; var workspace: UUID? = nil /* its workspace; nil only for scratch */ }
struct Workspace: Codable, Identifiable, Equatable, Sendable { var id: UUID; var name: String; var image: String? = nil /* file in Store.workspaceImages (128 px PNG, center-cropped by workspaceIconPNG; new name per image) */; var emoji: String? = nil; var color: Int? = nil /* rail palette index; nil = derived from id */; var lastProject: UUID? = nil /* reselected on switching back */ }   // icon = image, else emoji on a tint, else monogram(name)
func normalizeWorkspaces(_ l: inout Layout)   // at load: ≥1 workspace (old layouts get "Personal" holding everything), strays join the first, activeWorkspace follows the active project
struct Layout: Codable, Equatable, Sendable {
    var projects: [Project]; var activeProject: Int /* -1 = none (the last active project was hidden) */; var sidebarVisible: Bool; var theme: String
    var showHidden: Bool? = nil   // sidebar shows the Hidden list instead of Active (view state; nil = Active)
    var workspaces: [Workspace]? = nil; var activeWorkspace: UUID? = nil   // never empty / always valid after load
    static let `default`: Layout
}
@MainActor final class Store {
    static let directory: URL            // ~/Library/Application Support/Workbench (created on first use)
    static let workspaceImages: URL      // directory/workspaces
    var layout: Layout                   // mutate, then call changed()
    init()                               // loads directory/layout.json, falls back to .default on missing/corrupt
    func changed()                       // debounced 500 ms save on a private serial queue, atomic write
    func flush()                         // synchronous save; cancels pending debounce
}

// Runtime.swift
enum PaneEvent: Sendable {
    case title(String), pwd(String), bell, notification(title: String, body: String)
    case commandFinished(exitCode: Int, durationNs: UInt64)
    case openURL(String), closeRequested(processAlive: Bool)
    case startSearch(String), endSearch, searchTotal(Int), searchSelected(Int)
    case clone(CloneWatch.Event)   // a cloning pane's git output
}
@MainActor protocol RuntimeDelegate: AnyObject {
    func surfaceView(for id: PaneID) -> SurfaceView?
    func runtime(_ runtime: Runtime, pane: PaneID, event: PaneEvent)
}
@MainActor final class Runtime {
    let app: ghostty_app_t
    weak var delegate: RuntimeDelegate?
    init(overrides: String)              // default files + recursive files, then ghostty_config_load_string(overrides), finalize, ghostty_app_new
    func reload(overrides: String)       // build new config the same way, ghostty_app_update_config, free old config
    func setFocus(_ focused: Bool)       // ghostty_app_set_focus
}

// Session.swift — surviving sessions. Ghostty runs in manual IO mode (io_mode MANUAL: spawns nothing; output in via ghostty_surface_process_output, keys/replies out via io_write_cb). Each terminal pane's shell is owned by a `wbhost` process (Sources/wbhost/main.c, protocol in its header; bundled as Contents/Helpers/WorkbenchHost) listening on Store.directory/s/<PANE-UUID>, spawned with posix_spawn (setsid, no inherited fds) via Session.shell (the env/argv Ghostty's exec backend built: TERM/TERMINFO, zsh shell integration, login wrapper). SurfaceView init: Session.attach(id) else Session.spawn; the host replays recent output on attach (writes during the replay are dropped: they are Ghostty's replies to old queries). Socket EOF = shell ended → closeRequested(processAlive: false), unless the host's socket file is still there (Session.wasKilled: every normal host exit unlinks it, so the host was killed, e.g. a broad pkill or a force-quit of an app launched from the pane, which takes the pane's coalition) → sessionLost: WorkspaceController.restartLost starts a new session in the same pane rerunning its saved command; killed again within 30 s, the pane stays with a note. Quit ends sessions (close → kill); a crash leaves them running and the next launch reattaches; "Restart Workbench" (app menu) sets Session.keepOnClose so closing detaches, then relaunches. At launch Session.endOrphans(keeping:) kills hosts whose pane is no longer in the layout. The fd is closed only on the write queue by kill()/detach(), after stopReading().
// SurfaceView.swift
final class SurfaceBox: Sendable { let id: PaneID; let session: Mutex<Session?>; init(id: PaneID) }   // C userdata (passUnretained); owned by SurfaceView
@MainActor final class SurfaceView: NSView, NSTextInputClient {
    let paneID: PaneID
    let box: SurfaceBox
    private(set) var surface: ghostty_surface_t?
    var onFocus: ((PaneID) -> Void)?                     // called from becomeFirstResponder
    // drops: file URLs (Finder, file tree rows) paste their Runtime.shellEscape'd paths, space-separated, plus a trailing space
    var onKey: ((PaneID) -> Void)?                       // every keyDown: a key into a pane whose agent still has its OSC 9;4 progress up (Claude waiting on a question/plan approval) puts it back to busy; Claude 2.1.30x no longer animates its title, so progress + hooks are the busy signals
    var contextMenu: ((PaneID) -> NSMenu?)?              // right-click menu: the "Move to Tab" targets (other tabs, New Tab); set by WorkspaceController. Over a link the view adds Copy Link on top: link(at:) hovers with ⌘ mods so Ghostty resolves it (OSC 8 URI or regex URL) and reports it via MOUSE_OVER_LINK, synchronously on main, into hoveredLink; endLinkHover restores the real mods. ⌘-click paths: WorkspaceController.clickedPath — agents hard-wrap long paths, so Ghostty matches one row's part, or nothing (onPathClick fires on a ⌘-mouseUp with no hovered link); wordAtMouse (quicklook_word + the exact rows around it) is rejoined over the line breaks and the longest join that exists opens, ahead of Ghostty's own match (which can be the folder before a break after /)
    static var isReservedShortcut: (NSEvent) -> Bool = { _ in false }   // set by AppDelegate; performs the matching Pane menu action and returns true, else false
    init(app: ghostty_app_t, id: PaneID, cwd: String, initialInput: String?, env: [String: String], scrollbackLimit: Int?)
    @discardableResult func setVisible(_ visible: Bool) -> Bool   // hide: occlusion(false), realized(false); show: realized(true), occlusion(true), refresh. Realize state is kept only when libghostty accepts it, so a refused one retries on the next call. True = just shown (already refreshed).
    func syncFocus()                     // libghostty focus = first responder && key window (a focused surface runs blink + termios-poll timers); WorkspaceController calls it on window key changes
    func setCursorShape(_ shape: ghostty_action_mouse_shape_e)
    func setCursorVisibility(_ visible: Bool)
    @discardableResult func perform(_ action: String) -> Bool   // ghostty_surface_binding_action
    var needsConfirmQuit: Bool
    func close()                         // idempotent: session.stopReading then kill() (ends the shell; detach() while Session.keepOnClose, i.e. Restart), then ghostty_surface_free on a utility queue; the view stays retained by that closure until free returns
}

// Input.swift — ports of Ghostty helpers
extension NSEvent { func ghosttyKeyEvent(_ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s; var ghosttyCharacters: String? }
enum GhosttyInput {
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags
}

// Theme.swift
struct Theme: Decodable, Sendable { let id: String; let name: String; let type: String; let ui: [String: String]; let terminal: [String: String] }
extension Theme {
    @MainActor static func all() -> [Theme]              // cached until reload(): system-dark/system-light ("Dark"/"Light", built in code: Terminal.app "Basic" colors, accents from system colors resolved under their fixed appearance), then Bundle.main.resourceURL/themes/*.json (bundled, read-only), then Store.directory/themes/*.json (user) overriding by id; sorted by name
    @MainActor static func reload()                      // rescan; Theme.userFiles[id] = file of the editable (user) themes
    @MainActor static func named(_ id: String) -> Theme  // falls back to "oceanic-v2", then first
    var isSystem: Bool; var appearance: NSAppearance?    // system-* ids; window appearance from `type` ("light" → .aqua, else .darkAqua), applied in paintTheme
    static let requiredUI: [String]; static let requiredTerminal: [String]   // every key the app reads; a custom theme must provide all
    func template(id:name:) -> String                    // complete theme JSON seeded with this theme's colors
    static func validate(_ text: String) -> Result<Theme, Invalid>   // JSON parses, id filename-safe (not system-*), name, type dark|light, required keys, every color parses; Invalid.message is user-facing
    @MainActor static func save(_ t: Theme, text: String) throws -> URL   // atomic write to Store.directory/themes/<id>.json
    func color(_ key: String) -> NSColor                  // ui[key] (hex #RRGGBB or rgba(r, g, b, a)); magenta if missing
    func terminalColor(_ key: String) -> NSColor          // terminal[key] (ANSI palette); ui foreground if missing
    var ghosttyConfig: String                             // newline-separated ghostty config lines for terminal colors + split-divider-color
}

// Notification.Name.themeChanged — posted by WorkspaceController.applyTheme (and so after any list change); the Theme menu (AppDelegate.rebuildThemeMenu: Dark, Light, separator, custom, current checked) and Settings refresh on it.

// InspectorPanes.swift — the right sidebar (inspector) is a column holding the TODO list or the file tree (⌥⌘B toggles it), switched by GlassSegments TODO | Files in the toolbar row: an inspector subview centered in the titlebar guide left of the inspector toggle, so it slides with the inspector (a toolbar item stays put and reflows) (WorkspaceController.showInspectorTab). TodoListView (Apple Notes-style: CheckCircle rows, Return inserts, Backspace on empty deletes, ↑↓ move, a blank new row (faint circle, no placeholder) shown only while the list is empty or you are adding (click below the items, or Return); text commits via target/action so Accessibility confirm works) edits Project.todos ([Todo]) of the active project, reloaded only when the active project changes (inspectorProject). Open/closed and the tab are per project too (Project.inspectorOpen / inspectorTab, applied on that same change; saveInspector records the toggle, a divider collapse via KVO on isCollapsed, and tab picks into the project on screen). GlassSegments segments are accessibility radio buttons.
// FileTreeView.swift — Files tab tree: lazy NSOutlineView of the active project's folder, FSEvents refresh; FileIcons.swift maps names/extensions/folders to bundled Material Icon Theme SVGs (Resources/fileicons, MIT); filter hides dotfiles and build folders (Layout.showClutterFiles); selecting a previewable file shows it in the tab's file pane without taking focus, double-click goes through open(URL) (the ⌘-click policy); right-click: Copy Path, Reveal in Finder, Open in VS Code (if installed), Open with Default App.
// SettingsWindow.swift — ⌘, ("Settings…" in the app menu): SettingsWindowController, a window with an NSTabViewController (.toolbar tab style; add panes as NSTabViewItems). "Themes" pane: Dark/Light cards (NSButton), Custom Themes list (radio per theme; user ones get Edit…/Delete with confirmation), "Add Custom Theme…". Add/Edit is a sheet with a monospace JSON editor prefilled by Theme.template (or the file); Save runs Theme.validate, shows the error inline, else Theme.save → Theme.reload → applyTheme. Selecting applies live via WorkspaceController.applyTheme.
// Backup.swift — Backup (version, machine, layout minus scratch projects, user themes by file name, workspace images as base64, Ghostty config). current()/encoded() throw instead of dropping files; Backup.maxSize (64 MB) caps every read/write; decode rejects newer versions and unsafe/over-255-byte file names. forSync strips selection/focus/titles/export time and agent launches (resume ids churn every turn) so unchanged setups make no commit. BackupSync: per-Mac file workbench-<thisMachine>.json; 10 min throttle (first change arms it, later ones ride along) on Store.onChange and app activation; run = write, add, commit only that path if changed, fetch, rebase @{u}, push only if ahead; stop() bumps a generation so queued work no-ops; flush() at quit waits ≤5 s; fetchBackups = fetch + rebase + decode every workbench-*.json (this Mac first). backupSelfCheck.
// Settings "Backup" pane (BackupViewController): Export…/Import…/Copy JSON/Paste JSON, or drop a .json. Snapshots call workspace.captureAgents() first. Import: Backup.decode → each missingProjects gets Locate… (relocate rewrites the path and tabs' cwds/file paths under it) / Remove Project / Cancel Import → confirm (warns if agents are mid-turn) → Backup.saveCurrent (Store.directory/backups/, the rollback) → AppDelegate.restore(_:rollback:): quit, Backup.install, on failure reinstall the rollback and write restore-error.txt (alert at next launch), relaunch via `open -n`. Git Sync: Connect… takes a remote URL (Layout.backupRemote, machine-local); BackupSync clones it to Store.directory/sync and owns that clone.

// Agents.swift — agent processes found by inherited PANE_ID; launcher (cc1/cc2/gpt1…) recovered from the user's zsh functions
enum Agents {
    static let claudeHookArgs: String; static let codexHookArgs: String
    static func discoverLaunchers()                       // once at launch, background
    static func running() -> [PaneID: String?]           // pane → resume command; nil = agent running but id unknown yet (keep the saved command), e.g. "cc2 --resume <id>", "gpt1 resume <thread id>" (id from argv, else a distinct recent CLI thread of its folder from CODEX_HOME/state_*.sqlite)
    static func transcript(for pane: PaneID) -> URL?    // the pane agent's session jsonl: Claude <config dir>/projects/*/<sessionId>.jsonl (globbed by name), Codex <CODEX_HOME>/sessions/Y/M/D/rollout-*-<threadId>.jsonl (newest dirs first); nil = no agent / not found. Scans processes + disk: off main
    static func backgroundWork(for pane: PaneID) -> Bool   // a Claude pane still has work after its turn ended: subagents (<session>/subagents/agent-*.meta.json without "finished", log touched in the last 15 min) or background shells/Monitors (agent children `zsh -c source …/shell-snapshots/…`), except a shell tree listening on TCP and under 2% CPU over 1 s (a dev server). WorkspaceController holds a busy→done turn end as busy while true, rechecking every 5 s. Off main, may block 1 s
}

// SplitTreeView.swift
enum FocusDirection: Sendable { case left, right, up, down }
@MainActor final class SplitTreeView: NSView {
    var onRatiosChanged: ((SplitNode) -> Void)?           // user dragged a divider; tree with updated ratios
    var onMove: ((PaneID, PaneID, FocusDirection) -> Void)?   // pane dragged by its header (shown when the tab has 2+ panes) onto a side of another
    var onHeaderClick: ((PaneID) -> Void)?
    func updateHeaders(focused: PaneID?, theme: Theme, status: (PaneID) -> PaneStatus, title: (PaneID) -> String)   // called from updateChrome; each header is a strip (theme background) above the pane with a glass capsule pill (status dot + title)
    init(provider: @escaping (PaneSpec) -> NSView)        // returns the existing leaf view for a pane (never creates duplicates)
    @discardableResult func render(_ root: SplitNode, dividerColor: NSColor) -> Bool   // false = unchanged, nothing rebuilt
    func clear()                                          // drop the tree and every view it retains
    func neighbor(of id: PaneID, _ direction: FocusDirection) -> PaneID?
}

// FilePaneView.swift — .md previewed, other files as monospace code highlighted via Syntax; reloads on file change. Read-only (selectable, links clickable). A regular `.file` pane in the split tree, focusable like a terminal (acceptsFirstResponder forwards to its text view; onFocus → paneFocused), so ⌘W closes it. WorkspaceController.openFile (⌘-click a path, `pane open`, Open File…, Files tree selection with focus false) retargets the tab's existing file pane (kind swapped, view destroyed and rebuilt by the provider) or splits one in right of the focused pane: one preview pane per tab
@MainActor final class FilePaneView: NSView { let paneID: PaneID; init(id: PaneID, path: String, theme: Theme); func apply(theme: Theme); func close() }

// WebPaneView.swift — a `.web` pane: WKWebView (file: URLs read their folder; inspectable), the page title reported to the pane header, clicked links go through open(URL). WorkspaceController.openWeb (`pane browse`) splits it right of a given pane in that pane's own tab, without moving the project, tab or focus, and makes its view at once so evals reach a tab not on screen. Evals sent before the first load finishes wait for it. Mods' panels (claude-mods) are its main user: they write their page to a file, browse it beside Claude's pane and drive it with eval.
@MainActor final class WebPaneView: NSView { let paneID: PaneID; var onFocus, onTitle, onOpenLink; init(id: PaneID, url: URL, theme: Theme); func evaluate(_ code: String, done: @escaping (String) -> Void) /* {"result": <JSON value, null when none>} or {"error": …} */; func apply(theme: Theme); func close() }

// Syntax.swift — tree-sitter grammars (SwiftPM packages; queries read from their resource bundles in Contents/Resources)
enum Syntax {
    static func key(for path: String) -> String?          // grammar key by extension (or file name, e.g. dockerfile); nil = unknown
    static func key(fence: String) -> String?             // markdown code fence info string → grammar key
    static func highlights(_ text: String, key: String) -> [(range: NSRange, name: String)]?   // thread-safe; UTF-16 ranges, less specific first
}

// Model.swift sidebar helpers: visibleProjectIndices(_:hidden:workspace:) is the active workspace's list and excludes scratch (so ⌘1–9, next/previous project, reorder and the Hidden count only see real projects); scratchProjectIndices(_:) -> [Int]. The sidebar table is one row per project (table row == visible project index).
// Workspace navigation (Go menu, reserved shortcuts): ⌃1–9 selectWorkspaceByTag (no-op past the count), ⌃⌘↑/↓ previous/next workspace, wrapping (WorkspaceController.cycleWorkspace).
// Back/Forward (mouse buttons 4/5, ⌃⌘←/→): history of {workspace, project, tab} recorded at the end of render(), max 100, entries for closed projects/tabs resolve to what still exists or are skipped.

// SidebarView.swift
struct SidebarRow: Equatable, Sendable { let id: UUID; let name: String; let path: String; let status: PaneStatus; var tabCount = 0; var clone: CloneStatus? = nil }   // status = busiest pane of the project; tabCount = its tabs (shown right of the row, omitted when 0; a project with none is dimmed unless selected); clone: progress ring + "Cloning… N%", git's prompt in the attention color, or "Clone failed: …" with Retry / Edit… / Remove (80 pt row, onCloneAction)
enum PaneStatus: Int, Comparable, Sendable { case idle = 0, busy = 1, done = 2, attention = 3 }   // Comparable by rawValue
@MainActor final class SidebarView: NSView {   // the WorkspaceRail at the leading edge; right of it the workspace's name as a large bold title, the Active/Hidden GlassSegments under it, then a native .sourceList table. Two lines per project (ProjectRowCell, 46 pt): status dot (grey idle, hollow ring with nothing open), name, then "Needs you / Working… / Done / N tabs / Nothing open". Selection = the active project, drawn by SelectionRowView (label color at 15%, the app-wide selection fill shared with the tab bar, switches and pane headers; its bar spans the same width as the Active/Hidden switch; native highlight off). update() restyles cells in place and reloads only when the row ids change. Projects reorder by press-and-drag on a row (SidebarTable.onPress → Reorder(vertical: true); a press released before the 4 pt threshold selects the row): the row lifts and follows the pointer, the others slide aside.
    var onSelect: ((Int) -> Void)?; var onRemove: ((Int) -> Void)?         // project indices are rows of the list shown; WorkspaceController maps rows to projects (visibleProjectIndices / reorderedProjects in Model.swift)
    var onShowHidden: ((Bool) -> Void)?                  // Active/Hidden segmented control above the list
    var onToggleHidden: ((Int) -> Void)?                 // context menu Hide Project (Active view) / Show Project (Hidden view); the menu also has Copy Path, Reveal in Finder and Open in VS Code (omitted when not installed) (handled in the view)
    var onRename: ((Int, String?) -> Void)?              // double-click a project row (or context menu Rename); nil = cancelled
    var onMove: ((Int, Int) -> Void)?                    // drag a project: from, to (final index after removal)
    var onMoveToWorkspace: ((Int, Int) -> Void)?         // project context menu "Move to Workspace" (2+ workspaces): row, workspace index
    let rail: WorkspaceRail
    func updateWorkspaces(_ items: [WorkspaceItem], selected: Int, theme: Theme)   // rail + title
    func update(rows: [SidebarRow], selected: Int, hiddenCount: Int, showingHidden: Bool, theme: Theme)   // selected -1 = none; skipped while a name is being edited (the rename's end re-renders)
}   // Add Project and Scratch Terminal (apple.terminal) are toolbar items (WorkspaceController), not sidebar buttons

// GlassSegments.swift — `GlassSegments(labels:)`: the tab bar's toggle look as a standalone view (glass capsule + sliding selection pill in the theme foreground at 15% (`tint`, set by the owner), same 0.28 s curve, Reduce Motion snaps); `onSelect: ((Int) -> Void)?`, `setLabel(_:at:)`, `select(_:animated:)`. Used by the sidebar's Active/Hidden switch. Scratch rows are soft rounded bars (5% label fill, 9% hover, 15% when selected; no glass).

// WorkspaceRail.swift — 60 pt rail, darker strip starting below the toolbar (black 16%) with a 1 px trailing divider, Slack-style: one 40 pt icon per workspace (gradient tile + rounded-bold monogram, or emoji on a soft tint, or image), status badge = busiest pane inside, selected marked by a bar at the rail's edge; glass + New Workspace below. Right-click: Rename…, Choose Emoji… (sheet with a field + character palette; first character kept), Choose Image… (NSOpenPanel), Color ▸ (6 named swatches, checkmark on the current; tints the monogram tile and emoji, not images), Use Monogram, Delete Workspace… (2+; projects move to the neighbour, nothing closed)
struct WorkspaceItem: Equatable, Sendable { let id: UUID; let name: String; let image: String? /* absolute path */; let emoji: String?; let color: Int?; let status: PaneStatus }
func monogram(_ name: String) -> String   // KWI → KWI, side-projects → SP, Personal → P
func workspaceIconPNG(_ url: URL, px: Int = 128) -> Data?
@MainActor final class WorkspaceRail: NSView { var onSelect, onRename, onChooseEmoji, onChooseImage, onClearIcon, onDelete: ((Int) -> Void)?; var onChooseColor: ((Int /* workspace */, Int /* palette */) -> Void)?; var onNew: (() -> Void)?; static let width: CGFloat; func update(_ items: [WorkspaceItem], selected: Int, theme: Theme) }

// TabBarView.swift
struct TabItem: Equatable, Sendable { let title: String; let status: PaneStatus }
@MainActor final class TabBarView: NSView {   // a toolbar item view: fixed 34 pt height, width hugs the tabs (full titles, no per-tab cap) up to `maxWidth`, which WorkspaceController.fitTabBar sets from the toolbar slot to the end of the terminals column (less the project title and, inspector collapsed, its toggle) on every mainPane resize; the width is a required constraint plus the intrinsic size, since the toolbar sizes view items to their minimum and re-measures only on intrinsic invalidation; overflowing tabs scroll sideways in a TabScrollView (the mouse wheel scrolls it too) and the selected tab is scrolled into view on selection and resize; system colors; selection pill is the theme foreground at 15% (a solid fill, not glass: it must read the same in active, inactive and fullscreen-reveal toolbars) and slides (reduce-motion respected)
    var onSelect: ((Int) -> Void)?; var onClose: ((Int) -> Void)?; var onNew: (() -> Void)?
    var onRename: ((Int, String?) -> Void)?              // double-click a tab; nil = cancelled
    var onMove: ((Int, Int) -> Void)?                    // drag a tab: from, to (lifted tab follows the cursor, others slide aside, snaps on release; then the model follows)
    func update(items: [TabItem], selected: Int, theme: Theme)
}

// Reorder.swift — the one drag gesture: trackDrag(from:in:_:) (4 pt threshold, closed hand; tabs, pane headers, sidebar rows),
// and Reorder().drag(views, from, by: offset, done:, commit:) for pick-up, drag and snap in a row of views (x axis; `Reorder(vertical: true)` for the sidebar's rows, y axis in the flipped table, +offset = down).

// InlineRename (TabBarView.swift): makes a label editable in place; Return/click away commits, Esc cancels. static var isEditing (render() skips refocusing the terminal while true)

// FindBar.swift
@MainActor final class FindBar: NSView {   // glass capsule, NSSearchField, glass chevron/xmark buttons; fades+scales when isHidden toggles; apply(theme:) is a no-op (system colors)
    var onChange: ((String) -> Void)?; var onNext: (() -> Void)?; var onPrevious: (() -> Void)?; var onClose: (() -> Void)?
    var text: String
    func show(needle: String); func setCounts(total: Int, selected: Int); func apply(theme: Theme)
}
// Find (WorkspaceController): ⌘F → find(). Agent pane (Agents.transcript resolved, off main) → agent mode: Claude fullscreen and Codex draw history on the alternate screen and scroll it themselves, so there is no scrollback. Typing (debounced 150 ms) counts matches in the transcript (none → no scrolling, bar shows 0); otherwise seek() writes PageUp/PageDown (`text:\x1b[5~`/`[6~`) and reads SurfaceView.viewportText() every 60 ms until the whitespace-stripped, case-folded query is on screen (after a page only the lines it brought in count), then `search:<text>` highlights it. Return/⌘G = older, ⇧Return/⇧⌘G = newer. Past the last match it pages back to it (restore); for a new query it pages back about as far as it went. 400-page cap. Any other pane, or no transcript → libghostty search (start_search / search:<text> / navigate_search / end_search).

// Transcript.swift — session jsonl → searchable entries; the terminal of a fullscreen-TUI agent only holds the visible screen
struct TranscriptEntry: Sendable, Equatable { enum Kind { case user, assistant, toolCall, toolOutput }; let kind: Kind; let text: String; let time: Date? }
struct TranscriptMatch: Sendable, Equatable { let entry: Int; let range: NSRange }   // one per occurrence; UTF-16 range in the entry's text
struct TranscriptResult: Sendable { let entries: [TranscriptEntry]; let matches: [TranscriptMatch] }   // matches in file order
enum TranscriptParser {
    static func entries(_ line: Data, codex: Bool) -> [TranscriptEntry]   // one jsonl line; Claude: user/assistant text, tool_use "<name> <compact json>", tool_result; Codex: response_item message/function_call/custom_tool_call (+ outputs); everything else, isMeta and injected context skipped
    static func matches(in entries: [TranscriptEntry], _ query: String) -> [TranscriptMatch]   // case- and diacritic-insensitive substring
}
final class TranscriptIndex: @unchecked Sendable { init(_ url: URL); var entries: [TranscriptEntry]; func update() }   // reads only appended complete lines since the last call; confined to TranscriptSearch's queue
enum TranscriptSearch {   // background queue; per-file index cache; a newer call supersedes older ones (stale results dropped)
    static func locate(_ pane: PaneID, done: @escaping @Sendable @MainActor (URL?) -> Void)
    static func search(_ url: URL, _ query: String, done: @escaping @Sendable @MainActor (TranscriptResult) -> Void)
    static func cancel()
}
// GitClone.swift + NewProjectSheet.swift: New Project (⇧⌘O, toolbar +): a sheet, Open Folder | Clone Repository (GlassSegments; opens on the kind used last).
struct GitRemote { init?(_ text: String) /* https/http/ssh/git/scp-like; nil for paths */; let url, host, path: String; var folder: String; func sameRepository(as:) -> Bool; func command(into folder: String) -> String /* git clone --progress -- <url> <folder> && cd <folder> */; static func checkout(at dir: String) -> (origin: String?, branch: String?)? /* reads .git/config + HEAD */ }
enum CloneStatus { case cloning(Int), waiting(String), failed(String) }; enum CloneAction { case retry, editURL, remove }
final class CloneWatch: Sendable { enum Event { case progress(Int), prompt(String), error(String) }; func scan(_ bytes: UnsafeRawBufferPointer) -> [Event]; func answered(); func reset() }   // SurfaceBox.watch (set while a pane clones) scans its output on the reader queue → PaneEvent.clone
// Clone: the project (path = <location>/<folder>, name = folder) is added at once; its terminal starts in <location> and the command is typed as initial input (never a Launch, so it is not rerun at restore). WorkspaceController.clones (in memory, by project id) feeds SidebarRow.clone; the pane's first commandFinished ends it: 0 → ordinary project (Files tab reloads, done notification), else failed (git's fatal: line, mapped). A key into a waiting pane answers the prompt. Retry types the command again into the same pane; Edit… reopens the sheet prefilled and replaces the project. Sheet: URL validated live, clipboard offered (read only when pasteboard access is Always Allow, else detected and read on click), Location popup = Layout.cloneLocations (recent, max 6, the default first) + parents of existing projects, Choose…; a destination that exists shows its origin/branch, Open Existing as Project when the origin matches, and "Or clone as" <folder>-N.
// Control.swift — unix socket at Store.directory/pane.sock, one JSON object per line ([String: String], up to 8 MB), one reply line. The handler replies through a callback, at once or later (eval waits on its page; 20 s cap, then {"error":"timed out"}). Commands: hook, list (kind terminal|file|web), focus, split, send, open, add, clone, browse {url, pane, ratio} → {"pane"}, eval {pane, code} → {"result"}, close {pane} (web panes only, no confirm); the CLI waits 25 s for browse/eval, 2 s otherwise.
final class ControlServer: @unchecked Sendable { init(path: String, handler: @escaping @MainActor ([String: String], @escaping @Sendable (String) -> Void) -> Void); func start(); func stop() }
enum ControlClient { static func run(_ args: [String]) -> Int32 }   // argv after the program name
```
