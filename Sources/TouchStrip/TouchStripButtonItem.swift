import AppKit

/// Generic NSCustomTouchBarItem that wraps any TouchStripAction.
/// ButtonRegistry creates one of these per registered action.
class TouchStripButtonItem: NSCustomTouchBarItem {
    let action: TouchStripAction
    private var button: NSButton!

    init(action: TouchStripAction) {
        self.action = action
        super.init(identifier: action.identifier)

        button = NSButton(title: action.title, target: self, action: #selector(tapped))
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        button.contentTintColor = action.tintColor
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: action.width),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
        view = button
        if let live = action as? LiveTouchStripAction {
            live.buttonUpdater = { [weak self] title, color in
                DispatchQueue.main.async {
                    self?.button.title = title
                    self?.button.contentTintColor = color
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        tsDebugLog("\(action.id): tapped\n")
        action.activate()
        // Refresh button so stateful actions (toggles) can update title/colour
        button.title = action.title
        button.contentTintColor = action.tintColor
    }
}
