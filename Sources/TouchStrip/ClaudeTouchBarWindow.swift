import AppKit

/// Middle Touch Bar — Claude identity + token counter + 3 permission buttons.
///
/// Buttons send keystrokes to Claude Desktop (⌘↩ Allow Once, ⌘⇧↩ Always Allow,
/// ⎋ Reject) and light up while Claude Desktop is frontmost. Precise per-dialog
/// detection was removed: it required Accessibility tree access that Claude's
/// Electron shell does not expose, so the front-app heuristic is the reliable signal.
final class ClaudeMainBar: NSObject, NSTouchBarDelegate {

    static let shared = ClaudeMainBar()

    private var bar: NSTouchBar?
    private weak var infoLabel: NSTextField?
    private var dialogMessage: String?
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
            .init("claude.always_allow"),
            .init("claude.reject"),
        ]
        bar = b
        present(b)
        startRefreshTimer()
        startFrontAppObserver()
        tsDebugLog("ClaudeMainBar: installed (baseline \(sessionStartTokens))\n")
    }

    // MARK: - DFR presentation

    private func present(_ bar: NSTouchBar) {
        if let handle = Self.dfrHandle,
           let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") {
            unsafeBitCast(sym, to: DFRShowsCloseBoxFn.self)(false)
        }
        let sel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        if NSTouchBar.responds(to: sel) {
            NSTouchBar.perform(sel, with: bar, with: nil)
            tsDebugLog("ClaudeMainBar: presentSystemModalTouchBar succeeded\n")
        } else {
            tsDebugLog("ClaudeMainBar: no presentation API found\n")
        }
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

        default: return nil
        }
    }

    private func makePermButton(title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.font       = .systemFont(ofSize: 13, weight: .regular)
        btn.isEnabled  = false
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 110).isActive = true
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
        if let msg = dialogMessage { return msg }
        guard let count = readRawTokenCount() else { return "—" }
        let session = max(0, count - sessionStartTokens)
        func fmt(_ n: Int) -> String { n >= 1_000 ? String(format: "%.0fk", Double(n) / 1_000) : "\(n)" }
        return "\(fmt(count))/\(fmt(session))"
    }

    // MARK: - Actions

    @objc private func allowOnceTapped()   { sendKey(0x24, flags: .maskCommand,               label: "Allow Once") }
    @objc private func alwaysAllowTapped() { sendKey(0x24, flags: [.maskCommand, .maskShift],  label: "Always Allow") }
    @objc private func rejectTapped()      { sendKey(0x35, flags: [],                          label: "Reject") }

    private func sendKey(_ key: CGKeyCode, flags: CGEventFlags, label: String) {
        guard let claude = runningClaude() else {
            tsDebugLog("claude-bar: \(label) — Claude not running\n"); return
        }
        let pid = claude.processIdentifier
        claude.activate(options: .activateIgnoringOtherApps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let src = CGEventSource(stateID: .hidSystemState),
                  let dn  = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
                  let up  = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
            else { return }
            dn.flags = flags; up.flags = flags
            dn.postToPid(pid); up.postToPid(pid)
            tsDebugLog("claude-bar: sent \(label) key=\(key) flags=\(flags.rawValue)\n")
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
            dialogMessage = claudeIsFront ? "Claude wants your permission" : nil
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
            guard let self, self.dialogMessage == nil else { return }
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
