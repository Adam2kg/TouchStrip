import AppKit
import Foundation

/// Claude Code CLI session usage — scans ~/.claude/projects/**/*.jsonl,
/// sums output_tokens from the last 5 hours (Claude Code's billing window),
/// and pushes a compact coloured number to the Control Strip button.
///
/// Colour ramp matches the middle-bar token display:
///   green < 50 k  →  yellow < 120 k  →  orange < 170 k  →  red 170 k+
///
/// Auto-refreshes every 30 s; tap forces immediate refresh.
final class ClaudeCodeUsageAction: TouchStripAction, LiveTouchStripAction {

    let id    = "cc-usage"
    var width: CGFloat { 56 }

    var buttonUpdater: ((String, NSColor) -> Void)?

    // Initial placeholder shown before first scan.
    var title: String      { "CC" }
    var tintColor: NSColor { NSColor(white: 0.45, alpha: 1) }

    private static let projectsDir = NSHomeDirectory() + "/.claude/projects"
    private static let windowSecs: TimeInterval = 5 * 3600

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.tick()
        }
    }

    func activate() { tick() }

    // MARK: - Scan

    private func tick() {
        let tokens = readRecentOutputTokens()
        let text: String
        switch tokens {
        case ..<0:    text = "CC:?"
        case ..<1000: text = "\(tokens)"
        default:      text = String(format: "%.0fk", Double(tokens) / 1_000)
        }
        let color: NSColor
        switch tokens {
        case ..<0:       color = NSColor(white: 0.45, alpha: 1)
        case ..<50_000:  color = NSColor(red: 0.55, green: 0.90, blue: 0.55, alpha: 1)
        case ..<120_000: color = NSColor(red: 1.00, green: 0.85, blue: 0.20, alpha: 1)
        case ..<170_000: color = NSColor(red: 1.00, green: 0.55, blue: 0.10, alpha: 1)
        default:         color = NSColor(red: 1.00, green: 0.28, blue: 0.28, alpha: 1)
        }
        tsDebugLog("cc-usage: \(text) (\(max(0, tokens)) output tokens in last 5 h)\n")
        buttonUpdater?(text, color)
    }

    // MARK: - JSONL scanning

    private func readRecentOutputTokens() -> Int {
        let cutoff = Date().addingTimeInterval(-Self.windowSecs)
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: Self.projectsDir)
        else { return -1 }

        var total = 0
        for project in projects {
            let dir = Self.projectsDir + "/" + project
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                total += sumOutputTokens(in: dir + "/" + file, since: cutoff)
            }
        }
        return total
    }

    private func sumOutputTokens(in path: String, since cutoff: Date) -> Int {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        var sum = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard
                let data  = String(line).data(using: .utf8),
                let obj   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                obj["type"] as? String == "assistant",
                let tsStr = obj["timestamp"] as? String,
                let ts    = iso.date(from: tsStr),
                ts >= cutoff,
                let msg   = obj["message"] as? [String: Any],
                let usage = msg["usage"] as? [String: Any],
                let out   = usage["output_tokens"] as? Int
            else { continue }
            sum += out
        }
        return sum
    }
}
