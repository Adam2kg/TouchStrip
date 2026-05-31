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
    private weak var tokenLabel: NSTextField?
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

    private static let colorAllowOnce   = NSColor(red: 0.18, green: 0.65, blue: 0.32, alpha: 1)
    private static let colorAlwaysAllow = NSColor(red: 0.18, green: 0.45, blue: 0.88, alpha: 1)
    private static let colorReject      = NSColor(red: 0.85, green: 0.22, blue: 0.22, alpha: 1)
    private static let colorDim         = NSColor(white: 0.22, alpha: 1)

    private static let dialogTitles: Set<String> = ["Allow Once", "Always Allow", "Deny", "Reject"]

    // MARK: - Public

    func install() {
        permButtons.removeAll()
        sessionStartTokens = max(sessionStartTokens, readRawTokenCount() ?? 0)
        let b = NSTouchBar()
        b.delegate = self
        b.defaultItemIdentifiers = [
            .init("claude.tokens"),
            .init("claude.allow_once"),
            .init("claude.always_allow"),
            .init("claude.reject"),
            .flexibleSpace,
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
        case "claude.tokens":
            let item  = NSCustomTouchBarItem(identifier: id)
            let (text, color) = currentTokenDisplay()
            let label = NSTextField(labelWithString: text)
            label.font            = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            label.textColor       = color
            label.isBezeled       = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 96).isActive = true
            tokenLabel = label
            item.view  = label
            return item

        case "claude.allow_once":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn  = makePermButton(title: "Allow Once",  color: Self.colorAllowOnce,
                                      action: #selector(allowOnceTapped))
            permButtons.append(btn); item.view = btn; return item

        case "claude.always_allow":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn  = makePermButton(title: "Always Allow", color: Self.colorAlwaysAllow,
                                      action: #selector(alwaysAllowTapped))
            permButtons.append(btn); item.view = btn; return item

        case "claude.reject":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn  = makePermButton(title: "Reject",      color: Self.colorReject,
                                      action: #selector(rejectTapped))
            permButtons.append(btn); item.view = btn; return item

        default: return nil
        }
    }

    private func makePermButton(title: String, color: NSColor, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelColor = Self.colorDim
        btn.isEnabled  = false
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return btn
    }

    // MARK: - Actions

    @objc private func allowOnceTapped()   { sendClick(xFrac: 0.25, label: "Allow Once") }
    @objc private func alwaysAllowTapped() { sendClick(xFrac: 0.55, label: "Always Allow") }
    @objc private func rejectTapped()      { sendClick(xFrac: 0.82, label: "Reject") }

    private func sendClick(xFrac: CGFloat, label: String) {
        guard let claude = runningClaude() else {
            tsDebugLog("claude-bar: \(label) — Claude not running\n"); return
        }
        let pid = claude.processIdentifier
        claude.activate(options: .activateIgnoringOtherApps)
        guard let win = mainWindow(pid: pid) else {
            tsDebugLog("claude-bar: \(label) — no main window\n"); return
        }
        let pt = CGPoint(x: win.origin.x + win.width * xFrac,
                         y: win.origin.y + win.height * 0.65)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let src = CGEventSource(stateID: .hidSystemState),
                  let dn  = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                                    mouseCursorPosition: pt, mouseButton: .left),
                  let up  = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                                    mouseCursorPosition: pt, mouseButton: .left)
            else { return }
            dn.postToPid(pid); up.postToPid(pid)
            tsDebugLog("claude-bar: clicked \(label) at (\(Int(pt.x)),\(Int(pt.y))) win=\(win)\n")
        }
    }

    private func mainWindow(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for win in list {
            guard win[kCGWindowOwnerPID as String] as? pid_t == pid,
                  (win[kCGWindowLayer as String] as? Int) == 0,
                  let b = win[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
                  w > 200, h > 200
            else { continue }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
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
            if axDialogVisible { axDialogVisible = false; applyButtonState() }
            return
        }
        let found = axHasDialogButtons(pid: claude.processIdentifier)
        if found != axDialogVisible {
            axDialogVisible = found
            applyButtonState()
            tsDebugLog("claude-bar: AX dialog \(found ? "detected ▶" : "gone ◀")\n")
        }
    }

    private func axHasDialogButtons(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var queue: [(AXUIElement, Int)] = [(app, 0)]
        while !queue.isEmpty {
            let (el, depth) = queue.removeFirst()
            guard depth < 8 else { continue }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if role as? String == kAXButtonRole as String {
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title)
                if let t = title as? String, Self.dialogTitles.contains(t) { return true }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
               let kids = children as? [AXUIElement] {
                kids.forEach { queue.append(($0, depth + 1)) }
            }
        }
        return false
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
            applyButtonState()
            tsDebugLog("claude-bar: front=\(app.localizedName ?? "?") → buttons \(claudeIsFront ? "active" : "dim")\n")
        }
    }

    // MARK: - Button state

    /// Single place that decides active/dim based on whichever tier is running.
    private func applyButtonState() {
        let active = AXIsProcessTrusted() ? axDialogVisible : claudeIsFront
        let colors: [NSColor] = [Self.colorAllowOnce, Self.colorAlwaysAllow, Self.colorReject]
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for (i, btn) in self.permButtons.enumerated() {
                btn.bezelColor = active ? colors[i] : Self.colorDim
                btn.isEnabled  = active
            }
        }
    }

    // MARK: - Token refresh

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let (text, color) = self.currentTokenDisplay()
            DispatchQueue.main.async {
                self.tokenLabel?.stringValue = text
                self.tokenLabel?.textColor   = color
            }
        }
    }

    private func currentTokenDisplay() -> (String, NSColor) {
        guard let count = readRawTokenCount()
        else { return ("—", NSColor(white: 0.5, alpha: 1)) }
        let session = max(0, count - sessionStartTokens)
        func fmt(_ n: Int) -> String { n >= 1_000 ? String(format: "%.0fk", Double(n)/1_000) : "\(n)" }
        let text  = "\(fmt(count))/\(fmt(session))"
        let color: NSColor
        switch count {
        case ..<50_000:  color = NSColor(red: 0.55, green: 0.90, blue: 0.55, alpha: 1)
        case ..<120_000: color = NSColor(red: 1.00, green: 0.85, blue: 0.20, alpha: 1)
        case ..<170_000: color = NSColor(red: 1.00, green: 0.55, blue: 0.10, alpha: 1)
        default:         color = NSColor(red: 1.00, green: 0.28, blue: 0.28, alpha: 1)
        }
        if text != lastLoggedTokenText {
            tsDebugLog("claude-bar: tokens today=\(count) session=\(session) → \(text)\n")
            lastLoggedTokenText = text
        }
        return (text, color)
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
