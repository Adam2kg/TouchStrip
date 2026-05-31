import AppKit

/// Presents our custom bar in the main (middle) Touch Bar area using
/// DFRFoundation's system-modal API — the same mechanism Claude Desktop
/// uses for its own "Allow / Reject" permission dialogs in the Touch Bar.
///
/// This persists regardless of which app is frontmost, without needing
/// a key window and without stealing keyboard focus.
final class ClaudeMainBar: NSObject, NSTouchBarDelegate {

    static let shared = ClaudeMainBar()

    private var bar: NSTouchBar?
    private weak var tokenLabel: NSTextField?
    private var refreshTimer: Timer?

    private static let tokenFile =
        NSHomeDirectory() + "/Library/Application Support/Claude/buddy-tokens.json"
    private static let claudeBundle = "com.anthropic.claudefordesktop"

    // DFRFoundation private symbols
    private typealias DFRShowsCloseBoxFn = @convention(c) (Bool) -> Void
    private static let dfrHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
               RTLD_LAZY)

    // MARK: - Public

    func install() {
        let b = NSTouchBar()
        b.delegate = self
        b.defaultItemIdentifiers = [
            .init("claude.tokens"),
            .init("claude.accept"),
            .flexibleSpace,
        ]
        bar = b
        present(b)
        startRefreshTimer()
        tsDebugLog("ClaudeMainBar: presented in middle Touch Bar area\n")
    }

    // MARK: - DFR system-modal presentation

    private func present(_ bar: NSTouchBar) {
        // Tell DFR not to show a close box on our modal
        if let handle = Self.dfrHandle,
           let sym = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") {
            let fn = unsafeBitCast(sym, to: DFRShowsCloseBoxFn.self)
            fn(false)
        }

        // Present the bar as a system modal — persists across app switches
        // macOS 26 selector (confirmed via runtime probe):
        let presentSel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        if NSTouchBar.responds(to: presentSel) {
            NSTouchBar.perform(presentSel, with: bar, with: nil)
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
            let label = NSTextField(labelWithString: currentTokenText())
            label.font            = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            label.textColor       = NSColor(white: 0.85, alpha: 1)
            label.isBezeled       = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 80).isActive = true
            tokenLabel = label
            item.view  = label
            return item

        case "claude.accept":
            let item = NSCustomTouchBarItem(identifier: id)
            let btn  = NSButton(title: "⏎  Accept", target: self,
                                action: #selector(acceptTapped))
            btn.bezelColor = NSColor(red: 0.18, green: 0.65, blue: 0.32, alpha: 1)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 120).isActive = true
            item.view = btn
            return item

        default:
            return nil
        }
    }

    // MARK: - Actions

    @objc private func acceptTapped() {
        guard let claude = runningClaude(),
              let src = CGEventSource(stateID: .hidSystemState),
              let dn  = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true),
              let up  = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)
        else { return }
        let pid = claude.processIdentifier
        dn.postToPid(pid)
        up.postToPid(pid)
        tsDebugLog("claude-bar: sent ↩ to claude (pid \(pid))\n")
    }

    // MARK: - Token refresh

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let text = self.currentTokenText()
            DispatchQueue.main.async { self.tokenLabel?.stringValue = text }
        }
    }

    private func currentTokenText() -> String {
        guard let data  = try? Data(contentsOf: URL(fileURLWithPath: Self.tokenFile)),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let today = json["tokens-today"] as? [String: Any],
              let count = today["tokens"] as? Int
        else { return "T: —" }
        return count >= 1_000
            ? String(format: "T: %.1fk", Double(count) / 1_000)
            : "T: \(count)"
    }

    private func runningClaude() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.claudeBundle }
    }
}
