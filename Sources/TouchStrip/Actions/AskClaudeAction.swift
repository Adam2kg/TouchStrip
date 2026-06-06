import AppKit
import Foundation
import Security

// ── Ask Claude — Touch Bar vision button ─────────────────────────────────────
//
// Tap 🤖 → captures frontmost window → sends to Claude vision API →
//          shows truncated answer on button (green)
// Tap again → copies full answer to clipboard → resets to 🤖
//
// API key resolution order:
//   1. ANTHROPIC_API_KEY env var (inherited from shell when launched from terminal)
//   2. Keychain  (service: com.touchstrip.app, account: anthropic-api-key)
//      Store with: security add-generic-password -s com.touchstrip.app
//                      -a anthropic-api-key -w "sk-ant-..."
// ──────────────────────────────────────────────────────────────────────────────

// MARK: - State

private enum AskClaudeState {
    case idle
    case capturing
    case waiting
    case result(brief: String, full: String)
    case error(String)
}

// MARK: - Action

final class AskClaudeAction: TouchStripAction, LiveTouchStripAction {

    // TouchStripAction
    let id    = "ask-claude"
    var width: CGFloat { 44 }           // same as other Control Strip buttons

    var title: String {
        switch state {
        case .idle:                 return "🤖"
        case .capturing:            return "📸"
        case .waiting:              return "⏳"
        case .result(let b, _):    return b
        case .error(let msg):       return msg
        }
    }

    var tintColor: NSColor {
        switch state {
        case .idle:       return .white
        case .capturing:  return NSColor(red: 1, green: 0.85, blue: 0, alpha: 1)   // amber
        case .waiting:    return NSColor(red: 1, green: 0.85, blue: 0, alpha: 1)   // amber
        case .result:     return NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1) // green
        case .error:      return NSColor(red: 1, green: 0.28, blue: 0.28, alpha: 1) // red
        }
    }

    // LiveTouchStripAction
    var buttonUpdater: ((String, NSColor) -> Void)?

    // MARK: - Private state

    private var state: AskClaudeState = .idle

    // MARK: - Activate

    func activate() {
        switch state {

        case .result(_, let full):
            // Second tap: copy full response and reset
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(full, forType: .string)
            tsDebugLog("ask-claude: copied full response (\(full.count) chars) to clipboard\n")
            setState(.idle)
            return

        case .waiting, .capturing:
            tsDebugLog("ask-claude: already in flight, ignoring tap\n")
            return

        case .idle, .error:
            break
        }

        // Resolve API key before doing any work
        guard let apiKey = resolveAPIKey() else {
            tsDebugLog("ask-claude: no API key — set ANTHROPIC_API_KEY env var or store in Keychain\n")
            setState(.error("⚠️ key?"))
            resetToIdleAfter(2)
            return
        }

        setState(.capturing)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            guard let jpegData = self.captureTopWindowJPEG() else {
                tsDebugLog("ask-claude: window capture failed\n")
                self.setState(.error("⚠️ cap"))
                self.resetToIdleAfter(2)
                return
            }

            tsDebugLog("ask-claude: captured \(jpegData.count / 1024) KB JPEG\n")
            self.setState(.waiting)
            self.callClaude(jpegData: jpegData, apiKey: apiKey)
        }
    }

    // MARK: - Window capture

    /// Finds the topmost non-TouchStrip window, shells out to `screencapture -l <id>`,
    /// loads the result, scales to ≤1024px longest side, encodes as JPEG at 75% quality.
    private func captureTopWindowJPEG() -> Data? {
        // Step 1: Find the topmost non-TouchStrip visible window
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let myPid = Int32(ProcessInfo.processInfo.processIdentifier)
        var targetWID: Int?

        for win in list {
            guard
                let pid    = win[kCGWindowOwnerPID as String] as? Int32, pid != myPid,
                let layer  = win[kCGWindowLayer as String] as? Int,       layer == 0,
                let bounds = win[kCGWindowBounds as String] as? [String: Any],
                let w      = bounds["Width"]  as? CGFloat, w > 100,
                let h      = bounds["Height"] as? CGFloat, h > 100,
                let wid    = win[kCGWindowNumber as String] as? Int
            else { continue }
            targetWID = wid
            break
        }

        guard let wid = targetWID else {
            tsDebugLog("ask-claude: no suitable window found\n")
            return nil
        }

        // Step 2: Shell out to screencapture — avoids the deprecated CGWindowListCreateImage
        //   -o  no drop shadow   -x  no shutter sound   -l  capture by window ID
        let tmpPath = NSTemporaryDirectory() + "ts-claude-cap.png"
        let sc = Process()
        sc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        sc.arguments = ["-o", "-x", "-l", "\(wid)", tmpPath]
        do {
            try sc.run(); sc.waitUntilExit()
        } catch {
            tsDebugLog("ask-claude: screencapture launch error — \(error)\n")
            return nil
        }
        guard sc.terminationStatus == 0 else {
            tsDebugLog("ask-claude: screencapture exit \(sc.terminationStatus)\n")
            return nil
        }

        // Step 3: Load → scale → encode JPEG
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        guard let srcImage = NSImage(contentsOfFile: tmpPath),
              let cgImage  = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            tsDebugLog("ask-claude: could not load captured PNG\n")
            return nil
        }

        let srcW = cgImage.width, srcH = cgImage.height
        let maxPx = 1024
        let divisor = max(1.0, Double(max(srcW, srcH)) / Double(maxPx))
        let dstW = Int((Double(srcW) / divisor).rounded())
        let dstH = Int((Double(srcH) / divisor).rounded())

        guard let ctx = CGContext(
            data: nil, width: dstW, height: dstH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        guard let scaled = ctx.makeImage() else { return nil }

        let bmpRep = NSBitmapImageRep(cgImage: scaled)
        return bmpRep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    // MARK: - Anthropic API call

    private func callClaude(jpegData: Data, apiKey: String) {
        let base64 = jpegData.base64EncodedString()

        let body: [String: Any] = [
            "model": "claude-sonnet-4-5",
            "max_tokens": 300,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": base64
                        ]
                    ],
                    [
                        "type": "text",
                        "text": "Describe what's on screen in 1-2 short sentences. Be very concise — answer will show in a narrow Touch Bar button."
                    ]
                ]
            ]]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            setState(.error("⚠️ json")); return
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey,        forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",  forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 30

        tsDebugLog("ask-claude: POST \(bodyData.count / 1024) KB to api.anthropic.com\n")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                tsDebugLog("ask-claude: network error — \(error.localizedDescription)\n")
                self.setState(.error("⚠️ net"))
                self.resetToIdleAfter(3)
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                tsDebugLog("ask-claude: no data (HTTP \(statusCode))\n")
                self.setState(.error("⚠️ \(statusCode)"))
                self.resetToIdleAfter(3)
                return
            }

            guard
                let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let content = json["content"] as? [[String: Any]],
                let first   = content.first,
                let text    = first["text"] as? String
            else {
                let raw = String(data: data, encoding: .utf8) ?? "(undecodable)"
                tsDebugLog("ask-claude: parse error (HTTP \(statusCode)) — \(raw.prefix(300))\n")
                self.setState(.error("⚠️ \(statusCode)"))
                self.resetToIdleAfter(3)
                return
            }

            let full  = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let cap   = 5    // 44pt button fits ~5 chars; tap to copy full text
            let brief = full.count > cap
                ? String(full.prefix(cap)) + "…"
                : full

            tsDebugLog("ask-claude: OK — \(full.prefix(120))\n")
            self.setState(.result(brief: brief, full: full))

            // Auto-reset after 45 s so button doesn't stay green indefinitely
            self.resetToIdleAfter(45, onlyIfResult: true)

        }.resume()
    }

    // MARK: - Helpers

    private func setState(_ s: AskClaudeState) {
        state = s
        buttonUpdater?(title, tintColor)
    }

    private func resetToIdleAfter(_ seconds: Double, onlyIfResult: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            if onlyIfResult, case .result = self.state {} else if onlyIfResult { return }
            self.setState(.idle)
        }
    }

    private func resolveAPIKey() -> String? {
        // 1. Environment variable (inherited from shell)
        let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        if !env.isEmpty { return env }

        // 2. Keychain — security add-generic-password -s com.touchstrip.app -a anthropic-api-key -w "sk-ant-..."
        var item: CFTypeRef?
        let q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.touchstrip.app",
            kSecAttrAccount as String: "anthropic-api-key",
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let raw  = String(data: data, encoding: .utf8) {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }

        // 3. Config file: ~/.touchstrip-api-key  (one line, just the key)
        //    Write with: echo "sk-ant-..." > ~/.touchstrip-api-key && chmod 600 ~/.touchstrip-api-key
        let configPath = NSHomeDirectory() + "/.touchstrip-api-key"
        if let raw = try? String(contentsOfFile: configPath, encoding: .utf8) {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }

        return nil
    }
}
