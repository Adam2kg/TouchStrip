import AppKit
import ApplicationServices

/// Middle Touch Bar — token counter + 3 permission buttons.
///
/// Detection is two-tier:
///   • Tier 1 (preferred): AX polling every 1 s searches Claude's accessibility tree
///     for "Allow Once" / "Always Allow" / "Deny" button elements. Requires TouchStrip
///     to be listed in System Settings → Privacy & Security → Accessibility.
///   • Tier 2 (fallback): NSWorkspace front-app observer. Buttons light up whenever
///     Claude Desktop is the frontmost application. Works with no extra permissions.
///
/// The tier in use is logged at startup: "AX detection active" or "front-app fallback".
final class ClaudeMainBar: NSObject, NSTouchBarDelegate {

    static let shared = ClaudeMainBar()

    private var bar: NSTouchBar?
    private weak var infoLabel: NSTextField?
    private var dialogMessage: String? = nil
    private var refreshTimer: Timer?
    private var pollTimer: Timer?
    private var sessionStartTokens: Int = 0
    private var lastLoggedTokenText: String = ""
    private var permButtons: [NSButton] = []

    // AX tier state
    private var axDialogVisible = false
    // Front-app tier state
    private var claudeIsFront = false

    private static let tokenFile =
        NSHomeDirectory() + "/Library/Application Support/Claude/buddy-tokens.json"
    private static let claudeBundle = "com.anthropic.claudefordesktop"

    // DFRFoundation
    private typealias DFRShowsCloseBoxFn = @convention(c) (Bool) -> Void
    private static let dfrHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    private static let dialogTitles: Set<String> = ["Allow Once", "Always Allow", "Deny", "Reject"]

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

        if AXIsProcessTrusted() {
            tsDebugLog("claude-bar: AX detection active\n")
            startAXPoll()
        } else {
            tsDebugLog("claude-bar: front-app fallback (grant Accessibility in System Settings for precise detection)\n")
            startFrontAppObserver()
        }

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
            icon.translatesAutoresizingMaskIntoConstraints = false
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
                let cos = CGFloat(Foundation.cos(angle))
                let sin = CGFloat(Foundation.sin(angle))
                let perp = CGFloat(Foundation.cos(angle + .pi / 2))
                let psin = CGFloat(Foundation.sin(angle + .pi / 2))
                let inner: CGFloat = 2.5, outer: CGFloat = 7.5, w: CGFloat = 1.6
                path.move(to:  CGPoint(x: cx + inner*cos - w*perp, y: cy + inner*sin - w*psin))
                path.line(to:  CGPoint(x: cx + outer*cos,          y: cy + outer*sin))
                path.line(to:  CGPoint(x: cx + inner*cos + w*perp, y: cy + inner*sin + w*psin))
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

    @objc private func allowOnceTapped()   { sendKey(0x24, flags: .maskCommand,                  label: "Allow Once") }
    @objc private func alwaysAllowTapped() { sendKey(0x24, flags: [.maskCommand, .maskShift],    label: "Always Allow") }
    @objc private func rejectTapped()      { sendKey(0x35, flags: [],                             label: "Reject") }

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
            dn.flags = flags
            up.flags = flags
            dn.postToPid(pid)
            up.postToPid(pid)
            tsDebugLog("claude-bar: sent \(label) key=\(key) flags=\(flags.rawValue)\n")
        }
    }

    // MARK: - Tier 1: AX polling

    private func startAXPoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.axPollTick()
        }
    }

    private func axPollTick() {
        guard let claude = runningClaude() else {
            if axDialogVisible { axDialogVisible = false; dialogMessage = nil; applyButtonState() }
            return
        }
        let (found, msg) = axDialogInfo(pid: claude.processIdentifier)
        if found != axDialogVisible || msg != dialogMessage {
            axDialogVisible = found
            dialogMessage   = found ? msg : nil
            applyButtonState()
            tsDebugLog("claude-bar: AX dialog \(found ? "detected ▶ \(msg ?? "")" : "gone ◀")\n")
        }
    }

    private func axDialogInfo(pid: pid_t) -> (detected: Bool, message: String?) {
        let app = AXUIElementCreateApplication(pid)
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        var foundButton = false
        var message: String? = nil
        while !queue.isEmpty {
            let (el, depth) = queue.removeFirst()
            guard depth < 8 else { continue }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            let roleStr = role as? String ?? ""
            if roleStr == kAXButtonRole as String {
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title)
                if let t = title as? String, Self.dialogTitles.contains(t) { foundButton = true }
            }
            if roleStr == kAXStaticTextRole as String, message == nil {
                var val: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &val)
                if let t = val as? String, t.lowercased().contains("claude") { message = t }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
               let kids = children as? [AXUIElement] {
                kids.forEach { queue.append(($0, depth + 1)) }
            }
        }
        return (foundButton, foundButton ? message : nil)
    }

    // MARK: - Tier 2: front-app observer

    private func startFrontAppObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(frontAppChanged(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Set initial state from current frontmost app
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

    // MARK: - Button state

    /// Single place that decides active/dim based on whichever tier is running.
    private func applyButtonState() {
        let active = AXIsProcessTrusted() ? axDialogVisible : claudeIsFront
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.permButtons.forEach { $0.isEnabled = active }
            self.infoLabel?.stringValue = self.infoText()
        }
    }

    // MARK: - Token refresh

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.dialogMessage == nil else { return }
            DispatchQueue.main.async {
                self.infoLabel?.stringValue = self.infoText()
            }
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
