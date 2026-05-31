import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private static let pidFile = "/tmp/touchstrip.pid"

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? "=== TouchStrip launched @ \(Date()) ===\n"
            .write(toFile: "/tmp/ts-debug.txt", atomically: true, encoding: .utf8)

        guard acquireLock() else { NSApp.terminate(nil); return }

        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "▣"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit TouchStrip",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu

        // Permissions
        requestAccessibilityIfNeeded()
        requestScreenCaptureIfNeeded()

        // ── Register Touch Bar buttons ──────────────────────────────────────
        // To add a new button:
        //   1. Create Actions/MyAction.swift implementing TouchStripAction
        //   2. Add one line below: ButtonRegistry.shared.register(MyAction())
        // ───────────────────────────────────────────────────────────────────
        // Control Strip fills right→left: last registered = rightmost = always visible
        // B/I/U are lowest priority — they drop off first when space runs out
        // Control Strip (right side) — last registered = rightmost = never cut off
        ButtonRegistry.shared.register(BoldAction())
        ButtonRegistry.shared.register(ItalicAction())
        ButtonRegistry.shared.register(UnderlineAction())
        ButtonRegistry.shared.register(ScreenshotAction())
        ButtonRegistry.shared.register(FanAction())
        // ButtonRegistry.shared.register(MuteAction())
        // ButtonRegistry.shared.register(TimerAction())

        NSApp.activate(ignoringOtherApps: true)
        ButtonRegistry.shared.installAll()

        // Middle Touch Bar — DFR system-modal presentation (same API Claude Desktop uses)
        // Shows live token count + Accept button; persists across app switches
        ClaudeMainBar.shared.install()

        tsDebugLog("Setup complete ✓\n")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ButtonRegistry.shared.uninstallAll()
        try? FileManager.default.removeItem(atPath: Self.pidFile)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    // MARK: - Helpers

    private func acquireLock() -> Bool {
        if let existing = try? String(contentsOfFile: Self.pidFile),
           let pid = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 { return false }
        try? String(ProcessInfo.processInfo.processIdentifier)
            .write(toFile: Self.pidFile, atomically: true, encoding: .utf8)
        return true
    }

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    private func requestScreenCaptureIfNeeded() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }
}
