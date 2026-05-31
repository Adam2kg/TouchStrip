import AppKit

extension NSTouchBarItem.Identifier {
    static let tsVolume   = NSTouchBarItem.Identifier("com.touchstrip.volume")
    static let tsSkipBack = NSTouchBarItem.Identifier("com.touchstrip.skipBack")
    static let tsSkipFwd  = NSTouchBarItem.Identifier("com.touchstrip.skipFwd")
    static let tsTabs     = NSTouchBarItem.Identifier("com.touchstrip.tabs")
}

// TouchBarController manages the context bar (volume / skip / tabs).
// Control Strip buttons are now handled entirely by ButtonRegistry.
class TouchBarController: NSObject, NSTouchBarDelegate {
    let contextBar = NSTouchBar()

    private let browsers  = Set(["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.brave.Browser"])
    private let mediaApps = Set(["com.apple.QuickTimePlayerX", "com.colliderli.iina", "org.videolan.vlc", "io.mpv"])
    private var activeBundleID = ""

    override init() {
        super.init()
        contextBar.delegate = self
        contextBar.defaultItemIdentifiers = [.tsVolume]

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        activeBundleID = app.bundleIdentifier ?? ""

        var items: [NSTouchBarItem.Identifier] = [.tsVolume]
        if mediaApps.contains(activeBundleID) { items += [.tsSkipBack, .tsSkipFwd] }
        if browsers.contains(activeBundleID)  { items += [.tsSkipBack, .tsSkipFwd, .tsTabs] }
        contextBar.defaultItemIdentifiers = items

        if browsers.contains(activeBundleID),
           let tabItem = contextBar.item(forIdentifier: .tsTabs) as? TabItem {
            tabItem.refresh()
        }
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch id {
        case .tsVolume:   return VolumeItem(identifier: id)
        case .tsSkipBack: return SkipItem(identifier: id, direction: .back)
        case .tsSkipFwd:  return SkipItem(identifier: id, direction: .forward)
        case .tsTabs:     return TabItem(identifier: id)
        default:          return nil
        }
    }
}
