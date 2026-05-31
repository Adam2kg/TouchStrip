import AppKit

// ── Claude Desktop integration ────────────────────────────────────────────────
// ClaudeAcceptAction  — sends ⌘↩ (or plain ↩) to Claude Desktop
// ClaudeTokenAction   — shows today's token count; tap to refresh

private let claudeBundle = "com.anthropic.claudefordesktop"
private let tokenFile    = NSHomeDirectory() +
    "/Library/Application Support/Claude/buddy-tokens.json"

// MARK: - Accept (⌘↩)

/// Sends ⌘↩ to Claude Desktop — submits the current message.
/// If Claude isn't frontmost the keystroke still goes to whatever app is active.
struct ClaudeAcceptAction: TouchStripAction {
    let id    = "claude-accept"
    let title = "⏎"
    var width: CGFloat { 44 }

    func activate() {
        DispatchQueue.global(qos: .userInteractive).async {
            // Bring Claude to front first if it's running
            if let claude = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == claudeBundle }) {
                DispatchQueue.main.async {
                    claude.activate(options: .activateIgnoringOtherApps)
                }
                Thread.sleep(forTimeInterval: 0.2)
            }

            guard let src = CGEventSource(stateID: .hidSystemState),
                  let app = NSWorkspace.shared.frontmostApplication,
                  let dn  = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true),
                  let up  = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)
            else { return }

            // Plain Enter — Claude Desktop submits on Enter (Cmd+Enter is not needed)
            dn.postToPid(app.processIdentifier)
            up.postToPid(app.processIdentifier)
            tsDebugLog("claude-accept: sent ↩ to \(app.bundleIdentifier ?? "?")\n")
        }
    }
}

// MARK: - Token usage

/// Reads ~/Library/Application Support/Claude/buddy-tokens.json and
/// displays today's token count on the button.  Tap to refresh.
final class ClaudeTokenAction: TouchStripAction {
    let id    = "claude-tokens"
    var width: CGFloat { 80 }

    private var displayTitle = "T:…"

    var title: String {
        loadTitle()
        return displayTitle
    }

    func activate() {
        displayTitle = loadCount()
        tsDebugLog("claude-tokens: refreshed → \(displayTitle)\n")
    }

    // MARK: - Private

    @discardableResult
    private func loadTitle() -> String {
        displayTitle = loadCount()
        return displayTitle
    }

    private func loadCount() -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tokenFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let today = json["tokens-today"] as? [String: Any],
              let count = today["tokens"] as? Int
        else { return "T:?" }

        // Format: T:4.2k  or  T:98
        if count >= 1000 {
            let k = Double(count) / 1000.0
            return String(format: "T:%.1fk", k)
        }
        return "T:\(count)"
    }
}
