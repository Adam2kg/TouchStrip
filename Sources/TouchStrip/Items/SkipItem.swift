import AppKit

class SkipItem: NSCustomTouchBarItem {
    enum Direction { case back, forward }

    init(identifier: NSTouchBarItem.Identifier, direction: Direction) {
        super.init(identifier: identifier)
        let title = direction == .back ? "⏮" : "⏭"
        let button = NSButton(title: title, target: self, action: direction == .back ? #selector(skipBack) : #selector(skipForward))
        button.bezelStyle = .rounded
        view = button
    }

    required init?(coder: NSCoder) { fatalError() }

    // Media key codes: Previous=20, Next=17
    @objc private func skipBack()    { sendMediaKey(20) }
    @objc private func skipForward() { sendMediaKey(17) }

    private func sendMediaKey(_ key: Int32) {
        let data1 = Int((key << 16) | (0x0a << 8))
        for flags: UInt in [0xa00, 0xb00] {
            let e = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            e?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
