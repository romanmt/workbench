# Workbench

A fast, native macOS terminal workspace for running many Claude Code and Codex sessions side by side.
Swift 6 + AppKit on top of [libghostty](https://github.com/ghostty-org/ghostty) (Metal renderer, Zig VT core).

- Projects in a sidebar, tabs per project, split panes (⌘D right, ⇧⌘D down)
- Agent status per pane: a pulsing dot while Claude/Codex works, green when done, amber when it needs you
- Quit and reopen resumes every agent through the launcher it was started with (`cc2 --resume …`, `gpt1 resume --last`)
- ⌘V pastes clipboard images into Claude Code / Codex
- Native markdown preview (⌘-click a `.md` path, or `pane open file.md`), live-reloading
- Web panes for agents: `pane browse <file|url>` opens a page right of the pane, `pane eval <pane> <js>` drives it, `pane close <pane>` closes it (the claude-mods panels use them)
- Themes in Superset's JSON format (Oceanic v2 by default); your `~/.config/ghostty/config` still applies

## Build and install

Requires macOS 27+, Xcode with its Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`), zig 0.16 (`brew install zig@0.16`), and Ghostty.app installed (for terminfo).

```sh
scripts/ghosttykit.sh            # builds GhosttyKit.xcframework from our Ghostty fork (zig 0.16)
scripts/bundle.sh --install      # builds build.noindex/Workbench.app and copies it to /Applications
```

Update later with `scripts/update.sh` (pull, rebuild, install).

## Shortcuts

| | |
|---|---|
| ⌘T / ⌘W / ⇧⌘W | New tab / close pane / close tab |
| ⌘D / ⇧⌘D / ⇧⌘0 | Split right / split down / equalize |
| ⇧⌘[ ⇧⌘] | Previous / next tab |
| ⌘1–9, ⌘⌥↑ ⌘⌥↓ | Jump to project / previous, next project |
| ⇧⌘O / ⌘B | Add project / toggle sidebar |
| ⌘[ ⌘], ⌘⌥hjkl | Move focus between panes |
| ⌃1–9, ⌃⌘↑ ⌃⌘↓ | Jump to workspace / previous, next workspace |
| ⌘K / ⌘F / ⌘= ⌘- ⌘0 | Clear / find / font size |

## Control CLI

Every pane gets `PANE_ID` and `PANE_BIN`; agents can drive the app with
`"$PANE_BIN" list | focus <pane> | split [--down] [cmd] | send <pane> <text> | open <file.md> | browse <file|url> [--beside <pane>] [--ratio 0.33] | eval <pane> <js> | close <pane>`.

State lives in `~/Library/Application Support/Workbench/` (`layout.json`, `themes/`).
