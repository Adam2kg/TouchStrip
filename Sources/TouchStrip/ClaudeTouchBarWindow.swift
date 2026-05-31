import AppKit
import ApplicationServices

/// Presents our custom bar in the main (middle) Touch Bar area using
/// DFRFoundation's system-modal API.
///
/// Detection strategy: poll Claude Desktop's AX tree every 1s for button elements
/// whose titles match "Allow Once" / "Always Allow" / "Deny". Electron exposes these
/// even though its windows are hidden from the AX window list.
final class ClaudeMainBar: NSObject, NSTouchBarDelegate {

    static let shared = ClaudeMainBar()

    private var bar: NSTouchBar?
    private weak var tokenLabel: NSTextField?
    private var refreshTimer: Timer?
    private var pollTimer: Timer?
    private var sessionStartTokens: Int = 0
    private var lastLoggedTokenText: String = ""
    private var permButtons: [NSButton] = []
    private var dialogVisible = false

    private static let tokenFile =
        NSHomeDirectory() + "/Library/Application Support/Claude/buddy-tokens.json"
    private static let claudeBundle = "com.anthropic.claudefordesktop"

    // DFRFoundation private symbols
    private typealias DFRShowsCloseBoxFn = @convention(c) (Bool) -> Void
    private static let dfrHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
               RTLD_LAZY)

    private static let colorAllowOnce   = NSColor(red: 0.18, green: 0.65, blue: 0.32, alpha: 1)
    private static let colorAlwaysAllow = NSColor(red: 0.18, green: 0.45, blue: 0.88, alpha: 1)
    private static let colorReject      = NSColor(red: 0.85, green: 0.22, blue: 0.22, alpha: 1)
    private static let colorDim         = NSColor(white: 0.22, alpha: 1)

    // AX button titles that signal a permission dialog is showing
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
        startDialogPoll()
        tsDebugLog("ClaudeMainBar: installed (baseline \(sessionStartTokens))\n")
    }

    // MARK: - DFR system-modal presentation

    private func present(_ bar: NSTouchBar) {
        if let handle = Self.dfrHandle,
           let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") {
            let fn = unsafeBitCast(sym, to: DFRShowsCloseBoxFn.self)
            fn(false)
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
            let btn = makePermButton(title: "Allow Once",
                                     color: Self.colorAllowOnce,
                                     action: #selector(allowOnceTapped))
            permButtons.append(btn)
            item.view = btn
            return item

        case "claude.always_allow":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn = makePermButton(title: "Always Allow",
                                     color: Self.colorAlwaysAllow,
                                     action: #selector(alwaysAllowTapped))
            permButtons.append(btn)
            item.view = btn
            return item

        case "claude.reject":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn = makePermButton(title: "Reject",
                                     color: Self.colorReject,
                                     action: #selector(rejectTapped))
            permButtons.append(btn)
            item.view = btn
            return item

        default:
            return nil
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

    // MARK: - Permission button actions

    @objc private func allowOnceTapped()   { sendClick(xFrac: 0.25, label: "Allow Once") }
    @objc private func alwaysAllowTapped() { sendClick(xFrac: 0.55, label: "Always Allow") }
    @objc private func rejectTapped()      { sendClick(xFrac: 0.82, label: "Reject") }

    private func sendClick(xFrac: CGFloat, label: String) {
        guard let claude = runningClaude() else {
            tsDebugLog("claude-bar: \(label) tapped but Claude not running\n")
            return
        }
        let pid = claude.processIdentifier
        claude.activate(options: .activateIgnoringOtherApps)

        guard let win = mainWindow(pid: pid) else {
            tsDebugLog("claude-bar: \(label) — no main window found\n")
            return
        }

        let pt = CGPoint(
            x: win.origin.x + win.width  * xFrac,
            y: win.origin.y + win.height * 0.65
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let src = CGEventSource(stateID: .hidSystemState),
                  let dn = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                                   mouseCursorPosition: pt, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                                   mouseCursorPosition: pt, mouseButton: .left)
            else { return }
            dn.postToPid(pid)
            up.postToPid(pid)
            tsDebugLog("claude-bar: clicked \(label) at (\(Int(pt.x)),\(Int(pt.y))) win=\(win)\n")
        }
    }

    private func mainWindow(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for win in list {
            guard win[kCGWindowOwnerPID as String] as? pid_t == pid,
                  (win[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = win[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let w = bounds["Width"] as? CGFloat,
                  let h = bounds["Height"] as? CGFloat,
                  w > 200, h > 200
            else { continue }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    // MARK: - AX-based dialog detection

    private func startDialogPoll() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForDialog()
        }
    }

    private var axDiagLogged = false

    private func checkForDialog() {
        guard let claude = runningClaude() else {
            if dialogVisible { setPermButtonsActive(false) }
            return
        }
        let pid = claude.processIdentifier

        // One-time diagnostic: log whether AX can see Claude's tree at all
        if !axDiagLogged {
            axDiagLogged = true
            let app = AXUIElementCreateApplication(pid)
            var children: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children)
            let count = (children as? [AXUIElement])?.count ?? -1
            tsDebugLog("claude-bar: AX diag err=\(err.rawValue) children=\(count) trusted=\(AXIsProcessTrusted())\n")
        }

        let found = axHasDialogButtons(pid: pid)
        if found != dialogVisible {
            dialogVisible = found
            setPermButtonsActive(found)
            tsDebugLog("claude-bar: dialog \(found ? "detected" : "gone") via AX\n")
        }
    }

    /// Walk Claude's AX tree (breadth-first, max depth 8) looking for buttons
    /// whose titles match the permission dialog set. Returns true if any are found.
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
                if let t = title as? String, Self.dialogTitles.contains(t) {
                    return true
                }
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
               let kids = children as? [AXUIElement] {
                for kid in kids { queue.append((kid, depth + 1)) }
            }
        }
        return false
    }

    private func setPermButtonsActive(_ active: Bool) {
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

        func fmt(_ n: Int) -> String {
            n >= 1_000 ? String(format: "%.0fk", Double(n) / 1_000) : "\(n)"
        }
        let text = "\(fmt(count))/\(fmt(session))"

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
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.claudeBundle }
    }
}
