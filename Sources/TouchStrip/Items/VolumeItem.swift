import AppKit

class VolumeItem: NSCustomTouchBarItem {
    private var slider: NSSlider!

    override init(identifier: NSTouchBarItem.Identifier) {
        super.init(identifier: identifier)

        let current = Self.getVolume()
        slider = NSSlider(value: Double(current), minValue: 0, maxValue: 100, target: self, action: #selector(changed))
        slider.sliderType = .linear
        slider.frame = NSRect(x: 0, y: 0, width: 80, height: 30)

        let icon = NSTextField(labelWithString: "🔊")
        let stack = NSStackView(views: [icon, slider])
        stack.orientation = .horizontal
        stack.spacing = 4
        view = stack
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        Self.setVolume(Int(slider.intValue))
    }

    static func getVolume() -> Int {
        var error: NSDictionary?
        let result = NSAppleScript(source: "output volume of (get volume settings)")?.executeAndReturnError(&error)
        return Int(result?.int32Value ?? 50)
    }

    static func setVolume(_ level: Int) {
        NSAppleScript(source: "set volume output volume \(level)")?.executeAndReturnError(nil)
    }
}
