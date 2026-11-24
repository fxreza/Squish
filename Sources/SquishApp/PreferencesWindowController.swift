import AppKit

/// Settings. Every control reads/writes straight through to `Preferences.shared`
/// (UserDefaults suite com.fxreza.squish) - no Apply/OK, changes take effect
/// immediately, as a macOS settings pane should.
///
/// **Almost nothing lives here, on purpose.** Quality used to: three sliders, none of
/// which obviously agreed with the main window. Resize used to, as a "Limit long edge
/// to" checkbox nobody found. Output, Suffix, Output folder and Keep metadata used to -
/// which put the one thing people wanted to change, the `-squish` on every filename,
/// two windows away from the Compress button. All of them now have exactly one control
/// each, in the main window above the file list, where the result is visible while you
/// change it. What is left here is the launch default, which by definition cannot be a
/// property of the current window. A footer line says so out loud, so nobody comes
/// looking for the rest.
final class PreferencesWindowController: NSWindowController {

    private let prefs = Preferences.shared

    private let defaultModePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        self.init(window: window)
        buildUI()
        loadFromPreferences()
    }

    private func row(label: String, control: NSView, trailing: NSView? = nil) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.font = .systemFont(ofSize: 13)
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.widthAnchor.constraint(equalToConstant: 130).isActive = true

        var views: [NSView] = [labelField, control]
        if let trailing { views.append(trailing) }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        return stack
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        defaultModePopup.removeAllItems()
        defaultModePopup.addItems(withTitles: SquishMode.allCases.map(\.displayName))
        defaultModePopup.target = self
        defaultModePopup.action = #selector(defaultModeChanged)
        defaultModePopup.toolTip = "The mode a new window starts in. Switch modes in the window itself."

        let footnote = NSTextField(labelWithString:
            "Quality, Resize, Output, Suffix and Keep metadata live in the main window, above the file list.")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor

        let rows: [NSView] = [
            row(label: "Default mode:", control: defaultModePopup),
            NSBox.separatorLine(),
            row(label: "", control: footnote)
        ]

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    private func loadFromPreferences() {
        if let index = SquishMode.allCases.firstIndex(of: prefs.defaultMode) {
            defaultModePopup.selectItem(at: index)
        }
    }

    @objc private func defaultModeChanged() {
        prefs.defaultMode = SquishMode.allCases[defaultModePopup.indexOfSelectedItem]
    }

}

private extension NSBox {
    static func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
