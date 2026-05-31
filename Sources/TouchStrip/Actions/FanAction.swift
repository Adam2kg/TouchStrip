import AppKit
import Darwin  // kill()

/// Fan button — controls Macs Fan Control by writing its pref key and restarting it.
/// No Accessibility permission needed; no SMC privilege needed.
/// MFC's privileged helper applies the preset when MFC relaunches.
///
/// Tap 🌬️ → Full blast (MFC restarts with Predefined:0)
/// Tap 🥵  → Based on Airport sensor (UNSAVED|2,TW0P,50,60|2,TW0P,49,59)
final class FanAction: TouchStripAction {
    let id = "fan"

    var title: String      { isFullBlast ? "🌬️" : "🥵" }   // 🥵 = tap to blast, 🌬️ = blast active
    var tintColor: NSColor { isFullBlast ? .systemOrange : .white }

    private static let mfcBundle   = "com.crystalidea.macsfancontrol"
    private static let mfcPath     = "/Applications/Macs Fan Control.app"
    private static let idFullBlast = "Predefined:1"
    // Verified 2026-05-28: UNSAVED|2,TW0P,42,52|2,TW0P,49,59 — both fans based on Airport Proximity
    private static let idAirport   = "Unsaved:VU5TQVZFRHwyLFRXMFAsNDIsNTJ8MixUVzBQLDQ5LDU5"

    // Read current MFC state so the button reflects reality on launch
    private lazy var isFullBlast: Bool = {
        (readPreset() ?? Self.idAirport) == Self.idFullBlast
    }()

    func activate() {
        isFullBlast.toggle()
        let id = isFullBlast ? Self.idFullBlast : Self.idAirport
        DispatchQueue.global(qos: .userInitiated).async { self.switchPreset(to: id) }
    }

    // MARK: - Core logic

    private func switchPreset(to presetID: String) {
        // Skip if MFC already has this preset active (avoids unnecessary restart)
        if readPreset() == presetID {
            tsDebugLog("fan: already \(presetID), skipping\n")
            return
        }

        // 1. Write the new preset BEFORE killing MFC so the plist is set
        writePreset(presetID)
        tsDebugLog("fan: wrote ActivePreset = \(presetID)\n")

        // 2. Kill MFC with SIGKILL — prevents Qt from overwriting our plist change on exit
        if let mfc = runningMFC() {
            kill(mfc.processIdentifier, SIGKILL)
            tsDebugLog("fan: killed MFC (pid \(mfc.processIdentifier))\n")
            Thread.sleep(forTimeInterval: 0.8)
        }

        // 3. Relaunch MFC — it reads ActivePreset on startup and tells its helper to apply it
        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(fileURLWithPath: Self.mfcPath))
        }
        Thread.sleep(forTimeInterval: 2.5)

        // 4. Verify what MFC ended up with
        let actual = readPreset() ?? "(nil)"
        tsDebugLog("fan: preset applied. ActivePreset now = \(actual)\n")
    }

    // MARK: - MFC prefs helpers

    /// Reads MFC's ActivePreset via `defaults read` (bypasses UserDefaults cache).
    private func readPreset() -> String? {
        let out = runOutput("/usr/bin/defaults", "read",
                            Self.mfcBundle, "ActivePreset")
        return out?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes a new ActivePreset to MFC's plist via `defaults write`.
    private func writePreset(_ id: String) {
        run("/usr/bin/defaults", "write", Self.mfcBundle, "ActivePreset", id)
    }

    // MARK: - Process helpers

    @discardableResult
    private func run(_ exe: String, _ args: String...) -> Bool {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: exe)
        t.arguments = args
        t.standardOutput = Pipe(); t.standardError = Pipe()
        try? t.run(); t.waitUntilExit()
        return t.terminationStatus == 0
    }

    private func runOutput(_ exe: String, _ args: String...) -> String? {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: exe)
        t.arguments = args
        let pipe = Pipe()
        t.standardOutput = pipe; t.standardError = Pipe()
        try? t.run(); t.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func runningMFC() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == Self.mfcBundle }
    }
}
