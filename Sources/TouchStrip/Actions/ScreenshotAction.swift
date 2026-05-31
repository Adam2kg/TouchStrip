import AppKit

/// Touch Bar screenshot button.
/// Tap → camera cursor → hover to see blue window highlight → click → shutter → ⌘V paste.
struct ScreenshotAction: TouchStripAction {
    let id    = "screenshot"
    let title = "👀"

    func activate() {
        DispatchQueue.global(qos: .userInteractive).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-i", "-c", "-w"]
            // -i interactive   -c clipboard   -w window-mode only
            do {
                try task.run()
                task.waitUntilExit()
                tsDebugLog("screenshot: done (exit \(task.terminationStatus))\n")
            } catch {
                tsDebugLog("screenshot: error \(error)\n")
            }
        }
    }
}
