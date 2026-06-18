import AppKit
import ApplicationServices

/// Middle Touch Bar — Claude identity + live session token usage + action buttons.
///
/// Buttons send keystrokes to Claude Desktop and light up while Claude Desktop is
/// frontmost: Allow Once (⌘↩), Always Allow (Tab→Space), Reject (Tab Tab→Space),
/// Recents (⌘K, opens Claude's chat-search palette) and ↓ (Down arrow) to step
/// through it. Precise per-dialog detection
/// was removed: it required Accessibility tree access that Claude's Electron shell
/// does not expose, so the front-app heuristic is the reliable signal.
final class ClaudeMainBar: NSObject, NSTouchBarDelegate {

    static let shared = ClaudeMainBar()

    private var bar: NSTouchBar?
    private weak var infoLabel: NSTextField?
    private var refreshTimer: Timer?
    private var sessionStartTokens: Int = 0
    private var permButtons: [NSButton] = []
    private var claudeIsFront = false

    private static let tokenFile =
        NSHomeDirectory() + "/Library/Application Support/Claude/buddy-tokens.json"
    private static let claudeBundle = "com.anthropic.claudefordesktop"

    // DFRFoundation
    private typealias DFRShowsCloseBoxFn = @convention(c) (Bool) -> Void
    private static let dfrHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    // MARK: - Public

    func install() {
        permButtons.removeAll()
        sessionStartTokens = max(sessionStartTokens, readRawTokenCount() ?? 0)
        let b = NSTouchBar()
        b.delegate = self
        b.defaultItemIdentifiers = [
            .init("claude.identity"),
            .init("claude.info"),
            .init("claude.allow_once"),
            .init("claude.recents"),
            .init("claude.nav_down"),
            .init("claude.always_allow"),
            .init("claude.reject"),
        ]
        bar = b
        present(b)
        startRefreshTimer()
        startFrontAppObserver()
        tsDebugLog("ClaudeMainBar: AXIsProcessTrusted=\(AXIsProcessTrusted())  (synthetic keystrokes to other apps require this)\n")
        tsDebugLog("ClaudeMainBar: installed (baseline \(sessionStartTokens))\n")
    }

    // MARK: - DFR presentation

    private func present(_ bar: NSTouchBar) {
        if let handle = Self.dfrHandle,
           let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") {
            unsafeBitCast(sym, to: DFRShowsCloseBoxFn.self)(false)
        }
        // Presents a persistent strip in the MIDDLE of the Touch Bar via the PRIVATE
        // DFRFoundation API — the same mechanism Claude Desktop / BetterTouchTool use.
        // No public equivalent exists (NSTouchBar.principalItemIdentifier only centers
        // within a frontmost-app bar). Relying on a private framework makes the app
        // Mac App Store-ineligible — direct/notarized distribution only.
        //
        // macOS 13+ exposes this as presentSystemModalTouchBar:; older systems named the
        // same selector presentSystemModalFunctionBar:. Try the modern name, then fall
        // back. Both are guarded by responds(to:) so the app degrades gracefully if Apple
        // ever renames or removes the symbol.
        for name in ["presentSystemModalTouchBar:systemTrayItemIdentifier:",
                     "presentSystemModalFunctionBar:systemTrayItemIdentifier:"] {
            let sel = NSSelectorFromString(name)
            if NSTouchBar.responds(to: sel) {
                NSTouchBar.perform(sel, with: bar, with: nil)
                tsDebugLog("ClaudeMainBar: \(name) succeeded\n")
                return
            }
        }
        tsDebugLog("ClaudeMainBar: no presentation API found\n")
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch id.rawValue {
        case "claude.identity":
            let item  = NSCustomTouchBarItem(identifier: id)
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 5
            let icon = NSImageView(image: anthropicIcon())
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let label = NSTextField(labelWithString: "Claude")
            label.font      = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            stack.addArrangedSubview(icon)
            stack.addArrangedSubview(label)
            item.view = stack
            return item

        case "claude.info":
            let item  = NSCustomTouchBarItem(identifier: id)
            let label = NSTextField(labelWithString: infoText())
            label.font            = .systemFont(ofSize: 12, weight: .regular)
            label.textColor       = .white
            label.isBezeled       = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            infoLabel = label
            item.view  = label
            return item

        case "claude.allow_once":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn  = makePermButton(title: "Allow Once",   action: #selector(allowOnceTapped))
            permButtons.append(btn); item.view = btn; return item

        case "claude.always_allow":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn  = makePermButton(title: "Always Allow", action: #selector(alwaysAllowTapped))
            permButtons.append(btn); item.view = btn; return item

        case "claude.reject":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn  = makePermButton(title: "Reject",       action: #selector(rejectTapped))
            permButtons.append(btn); item.view = btn; return item

        case "claude.recents":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn  = makePermButton(title: "Recents", action: #selector(recentsTapped), width: 90)
            permButtons.append(btn); item.view = btn; return item

        case "claude.nav_down":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn  = makePermButton(title: "↓", action: #selector(navDownTapped), width: 60)
            permButtons.append(btn); item.view = btn; return item

        default: return nil
        }
    }

    private func makePermButton(title: String, action: Selector, width: CGFloat = 110) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.font       = .systemFont(ofSize: 13, weight: .regular)
        btn.isEnabled  = false
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: width).isActive = true
        return btn
    }

    private func anthropicIcon() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let cx = rect.midX, cy = rect.midY
            NSColor(red: 0.91, green: 0.38, blue: 0.17, alpha: 1).setFill()
            let path = NSBezierPath()
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4
                let cos = CGFloat(Foundation.cos(angle)), sin = CGFloat(Foundation.sin(angle))
                let perp = CGFloat(Foundation.cos(angle + .pi / 2)), psin = CGFloat(Foundation.sin(angle + .pi / 2))
                let inner: CGFloat = 2.5, outer: CGFloat = 7.5, w: CGFloat = 1.6
                path.move(to: CGPoint(x: cx + inner*cos - w*perp, y: cy + inner*sin - w*psin))
                path.line(to: CGPoint(x: cx + outer*cos,          y: cy + outer*sin))
                path.line(to: CGPoint(x: cx + inner*cos + w*perp, y: cy + inner*sin + w*psin))
                path.close()
            }
            path.fill()
            return true
        }
    }

    private func infoText() -> String {
        guard let count = readRawTokenCount() else { return "—" }
        let session = max(0, count - sessionStartTokens)
        func fmt(_ n: Int) -> String { n >= 1_000 ? String(format: "%.0fk", Double(n) / 1_000) : "\(n)" }
        return "\(fmt(count))/\(fmt(session))"
    }

    // MARK: - Actions

    // Claude Desktop's tool-permission dialog is a WebView of standard focusable HTML
    // buttons (verified in app.asar — no native button-array, no global key handler).
    // Enter/Space activates whatever button has FOCUS, and focus defaults to "Allow once".
    // So the other two buttons can only be triggered by moving focus there first.
    //   Allow once  : ⌘↩ on the default-focused button            (key 0x24 Return)
    //   Always allow: Tab → Space  (focus the 2nd button, activate) (0x30 Tab, 0x31 Space)
    //   Reject      : Tab Tab → Space (focus the 3rd button)
    // Space (0x31), not Return: Space always fires the focused button regardless of
    // whether "Allow once" is the form's default submit button.
    private typealias Stroke = (key: CGKeyCode, flags: CGEventFlags)

    @objc private func allowOnceTapped()   { sendKeys([(0x24, .maskCommand)],                   label: "Allow Once") }
    @objc private func alwaysAllowTapped() { sendKeys([(0x30, []), (0x31, [])],                 label: "Always Allow") }
    @objc private func rejectTapped()      { sendKeys([(0x30, []), (0x30, []), (0x31, [])],     label: "Reject") }
    // Recents = ⌘K (key 0x28) opens Claude's chat-search palette, which grabs keyboard focus
    // so the ↓ button can step through recent sessions. A bare ↓ alone just scrolls the chat.
    @objc private func recentsTapped()     { sendKeys([(0x28, .maskCommand)],                   label: "Recents (⌘K)") }
    // Down arrow (0x7D), no modifiers — steps through the focused Recents palette / a menu.
    @objc private func navDownTapped()     { sendKeys([(0x7D, [])],                             label: "Nav Down") }

    private func sendKeys(_ strokes: [Stroke], label: String) {
        guard let claude = runningClaude() else {
            tsDebugLog("claude-bar: \(label) — Claude not running\n"); return
        }
        claude.activate(options: .activateIgnoringOtherApps)
        // Wait for Claude to be frontmost, then play the strokes in order with a small
        // gap so the WebView processes each (focus move, then activation).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard let src = CGEventSource(stateID: .hidSystemState) else { return }
            for (i, stroke) in strokes.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                    guard let dn = CGEvent(keyboardEventSource: src, virtualKey: stroke.key, keyDown: true),
                          let up = CGEvent(keyboardEventSource: src, virtualKey: stroke.key, keyDown: false)
                    else { return }
                    dn.flags = stroke.flags; up.flags = stroke.flags
                    // Global HID post (not postToPid): Electron's renderer owns the focused
                    // dialog; a HID-level post routes through the normal input pipeline to
                    // the frontmost app (Claude, just activated).
                    dn.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                }
            }
            tsDebugLog("claude-bar: sent \(label) (\(strokes.count)-stroke sequence)\n")
        }
    }

    // MARK: - Detection (front-app heuristic)

    private func startFrontAppObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        claudeIsFront = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.claudeBundle)
        applyButtonState()
    }

    @objc private func frontAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let was = claudeIsFront
        claudeIsFront = (app.bundleIdentifier == Self.claudeBundle)
        if claudeIsFront != was {
            applyButtonState()
            tsDebugLog("claude-bar: front=\(app.localizedName ?? "?") → buttons \(claudeIsFront ? "active" : "dim")\n")
        }
    }

    private func applyButtonState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.permButtons.forEach { $0.isEnabled = self.claudeIsFront }
            self.infoLabel?.stringValue = self.infoText()
        }
    }

    // MARK: - Token refresh

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.infoLabel?.stringValue = self.infoText() }
        }
    }

    private func readRawTokenCount() -> Int? {
        guard let data  = try? Data(contentsOf: URL(fileURLWithPath: Self.tokenFile)),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let today = json["tokens-today"] as? [String: Any],
              let count = today["tokens"] as? Int
        else { return nil }
        return count
    }

    private func runningClaude() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == Self.claudeBundle }
    }
}
