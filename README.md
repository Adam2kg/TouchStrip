# TouchStrip

**I gave my MacBook's forgotten Touch Bar a job: driving Claude.**

TouchStrip is a tiny macOS menu-bar app that turns the Touch Bar into a control surface for **Claude Desktop** — respond to tool-permission prompts, jump through recent chats, and watch your session token count — plus a few general-purpose Control Strip buttons (text formatting, window screenshot, fan control).

It's a personal hack, shared in case it's useful to other Touch Bar holdouts. Not a polished product: you build it from source and grant it Accessibility.

> [!IMPORTANT]
> **It does not auto-approve anything.** The permission buttons are a faster *surface* for a decision you still make by hand — tapping **Reject** rejects, tapping **Allow** allows. There is no automation, no rule engine, nothing that answers prompts for you. The human stays in the loop; the loop just moved to the Touch Bar.

---

## Demo

> _TODO: add a 10-second screen recording / GIF of the Touch Bar buttons here — it's the whole pitch for a Touch Bar app._

---

## What it does

### Middle bar — Claude Desktop
Appears as a system-modal Touch Bar (the same presentation API Claude Desktop itself uses) and lights up while Claude Desktop is frontmost:

| Button | Action |
|--------|--------|
| **Allow Once** | Approves the current tool-permission prompt (`⌘↩`) |
| **Always Allow** | Approves and remembers (focus-traversal: `Tab → Space`) |
| **Reject** | Denies (`Tab Tab → Space`) |
| **Recents** | Opens Claude's chat-search palette (`⌘K`) |
| **↓** | Steps down through the open palette / a menu |
| _info_ | Live **session token usage** next to the Claude label |

### Control Strip — general purpose
| Button | Action |
|--------|--------|
| **B / I / U** | Sends ⌘B / ⌘I / ⌘U to the frontmost app — works in any rich-text editor (Mail, Notes, Pages, Notion, Google Docs…) |
| **👀** | Interactive window screenshot to clipboard (`screencapture -i -c -w`) |
| **🥵 / 🌬️** | Toggles [Macs Fan Control](https://crystalidea.com/macs-fan-control) between an Airport-sensor preset and full blast |

A menu-bar icon (`▣`) offers **Restore Touch Bar** and **Quit**.

---

## Requirements

- A **Touch Bar MacBook Pro** (2016–2023).
- **macOS 13 (Ventura)** or later.
- **Swift toolchain** (Xcode or the Command Line Tools) to build.
- **Claude Desktop** — for the middle bar.
- Optional: **Macs Fan Control** — only for the fan button.

---

## Build & run

```bash
git clone https://github.com/Adam2kg/TouchStrip.git
cd TouchStrip
make run        # builds (release), bundles TouchStrip.app, signs, launches
```

`make` targets: `build` (compile), `app` (bundle + sign), `run` (kill old + launch), `install` (copy to /Applications), `clean`.

---

## First run — permissions (read this)

macOS will not let one app send synthetic input to another without **Accessibility** permission. This is the single most common reason "the buttons do nothing."

1. On first launch TouchStrip prompts for **Accessibility** and **Screen Recording**.
2. Grant both in **System Settings → Privacy & Security**:
   - **Accessibility** → enable **TouchStrip** (required for the permission/nav buttons).
   - **Screen Recording** → enable **TouchStrip** (only for the 👀 screenshot button).
3. **Relaunch** TouchStrip after granting.

You can confirm it took: with TouchStrip running, `/tmp/ts-debug.txt` logs `AXIsProcessTrusted=true` at startup.

### The rebuild gotcha (important if you hack on it)

The Accessibility grant is bound to the app's **code signature**. `make` signs ad-hoc by default, so the signature changes on rebuilds — and a changed signature **silently invalidates the grant**, making the buttons go dead with no error.

If that happens, reset and re-grant:

```bash
tccutil reset Accessibility com.touchstrip.app
# then re-enable TouchStrip under System Settings → Privacy & Security → Accessibility
```

**To stop re-granting on every rebuild**, create a stable self-signed code-signing identity once:
*Keychain Access → Certificate Assistant → Create a Certificate…* → Name **`TouchStrip Dev`**, Identity Type *Self-Signed Root*, Certificate Type **Code Signing**. The `Makefile` automatically prefers an identity named `TouchStrip Dev` and only falls back to ad-hoc if it isn't found. With a stable cert, the grant survives rebuilds.

---

## How it works (the interesting part)

Claude Desktop is an Electron app, and its tool-permission dialog is an in-WebView set of focusable HTML buttons — **no native button array, no global key handler**, and the dialog is invisible to both `CGWindowList` and the Accessibility tree. So TouchStrip can't "see" the dialog or click a specific button by position. Two consequences shaped the design:

- **Keystrokes, not clicks.** Buttons are activated by *focus traversal*: focus defaults to "Allow once", so `Tab → Space` reaches "Always allow" and `Tab Tab → Space` reaches "Reject". `Space` fires the focused button regardless of which one is the form's default submit.
- **Global HID events, not per-PID.** Events are posted to `.cghidEventTap` (the global HID pipeline) rather than `postToPid`, because Electron's renderer owns the focused dialog and only sees events that come through the normal input path.
- **Front-app heuristic for enablement.** Since the dialog is unobservable, buttons simply enable whenever Claude Desktop is the frontmost app.

The Touch Bar itself is presented via the private `DFRFoundation` framework's `presentSystemModalTouchBar:` — the same mechanism Claude Desktop and other apps use to put a persistent strip in the middle of the bar.

---

## Caveats & limitations

- **Token counter** reads `~/Library/Application Support/Claude/buddy-tokens.json`, which is **not** a standard Claude Desktop file — it comes from a separate setup. Without it, the info slot just shows `—`. Treat this feature as setup-specific.
- **Fragile by nature.** The permission buttons depend on Claude Desktop's current dialog markup and Tab order. A Claude Desktop update could change that and require re-tuning the `Tab` counts in `ClaudeTouchBarWindow.swift`. ⚠️ Test on a low-stakes prompt after any Claude update — a wrong Tab count could make a button hit the wrong action.
- **Fan button** is specific to Macs Fan Control and to preset IDs verified on one machine; adjust for your own presets.

---

## Architecture

```
Sources/TouchStrip/
├── main.swift                 # entry point
├── AppDelegate.swift          # menu bar, permissions, button registration
├── ButtonRegistry.swift       # Control Strip button lifecycle
├── TouchStripAction.swift     # protocol every Control Strip button implements
├── TouchStripButtonItem.swift # NSTouchBarItem wrapper
├── ClaudeTouchBarWindow.swift # the middle Claude bar (permission/nav/tokens)
├── SMCController.swift         # SMC access (fan)
├── Utils.swift                # shared debug log (/tmp/ts-debug.txt)
└── Actions/
    ├── FormattingActions.swift  # B / I / U
    ├── ScreenshotAction.swift   # 👀
    └── FanAction.swift          # 🥵 / 🌬️
```

**Adding a Control Strip button:** implement `TouchStripAction` in a new `Actions/*.swift`, then add one `ButtonRegistry.shared.register(MyAction())` line in `AppDelegate`.

---

## License

No license yet — add one before reuse. (MIT is a reasonable default for a hack like this.)
