# TouchStrip

Persistent Touch Bar utility for macOS — screenshot to clipboard, fan control, and a live Claude Desktop token counter baked into the middle bar.

Runs as a menu bar app (▣). Single instance, starts silently, no windows.

## Buttons

**Control Strip (right side — always visible):**

| Button | What it does |
|--------|-------------|
| 👀 | Interactive window screenshot → clipboard. Tap, move cursor over any window to highlight it, click → instant ⌘V paste |
| 🌬️ / 🥵 | Fan control — toggles between full blast and Airport sensor mode via Macs Fan Control |
| **B I U** | Bold / Italic / Underline in the frontmost text field. Drop off first when Touch Bar space runs out |

**Middle bar (persists across all apps):**

Live Claude Desktop token counter (auto-refreshes every 5 s) + green Accept button (⏎) that sends Enter to Claude Desktop. Uses the same DFRFoundation private API that Claude Desktop itself uses for its Touch Bar dialogs.

## Requirements

- MacBook Pro with Touch Bar (2016–2021)
- macOS 12+
- Accessibility permission (prompted on first launch)
- Screen Recording permission (prompted on first launch)
- [Macs Fan Control](https://crystalidea.com/macs-fan-control) — for the fan button
- [Claude Desktop](https://claude.ai/download) — for the middle bar token counter

## Build & run

```bash
make app
open TouchStrip.app
```

Requires Xcode command line tools. The app self-signs on build.

To start at login: System Settings → General → Login Items → add TouchStrip.app.

## Notes

Uses `DFRFoundation.framework` (private API) for the Control Strip and middle bar. Works on macOS up to Sequoia; future OS updates may break it.

## License

MIT
