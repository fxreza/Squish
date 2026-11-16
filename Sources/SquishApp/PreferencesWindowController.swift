import AppKit

/// Settings. Every control reads/writes straight through to `Preferences.shared`
/// (UserDefaults suite com.fxreza.squish) - no Apply/OK, changes take effect
/// immediately, as a macOS settings pane should.
///
/// **Quality and Resize deliberately do not live here.** Quality used to: three
/// sliders, none of which agreed obviously with the main window. Resize used to, as a
/// "Limit long edge to" checkbox nobody found. Both now have exactly one control each,
/// in the main window above the file list, and this window is only about where output
/// goes and what it is called. A footer line says so out loud, so nobody comes
/// looking for them here.
final class PreferencesWindowController: NSWindowController {

    private let prefs = Preferences.shared

    private let defaultModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let outputBehaviorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let suffixField = NSTextField(string: "-squish")
    private let folderPathField = NSTextField(labelWithString: "")
    private let chooseFolderButton = NSButton(title: "Choose…", target: nil, action: nil)
    private let keepMetadataCheckbox = NSButton(checkboxWithTitle: "Keep metadata (EXIF + ICC)", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
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

        outputBehaviorPopup.removeAllItems()
        outputBehaviorPopup.addItems(withTitles: OutputBehavior.allCases.map(\.displayName))
        outputBehaviorPopup.target = self
        outputBehaviorPopup.action = #selector(outputBehaviorChanged)

        suffixField.target = self
        suffixField.action = #selector(suffixChanged)
        suffixField.delegate = self
        suffixField.widthAnchor.constraint(equalToConstant: 100).isActive = true

        folderPathField.isEditable = false
        folderPathField.isBordered = true
        folderPathField.font = .systemFont(ofSize: 11)
        folderPathField.lineBreakMode = .byTruncatingMiddle
        folderPathField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder)

        keepMetadataCheckbox.target = self
        keepMetadataCheckbox.action = #selector(keepMetadataChanged)

        let outputFolderRow = NSStackView(views: [folderPathField, chooseFolderButton])
        outputFolderRow.orientation = .horizontal
        outputFolderRow.spacing = 6

        let footnote = NSTextField(labelWithString: "Quality and Resize live in the main window, above the file list.")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor

        let rows: [NSView] = [
            row(label: "Default mode:", control: defaultModePopup),
            NSBox.separatorLine(),
            row(label: "Output:", control: outputBehaviorPopup),
            row(label: "Suffix:", control: suffixField),
            row(label: "Output folder:", control: outputFolderRow),
            NSBox.separatorLine(),
            row(label: "", control: keepMetadataCheckbox),
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
        if let index = OutputBehavior.allCases.firstIndex(of: prefs.outputBehavior) {
            outputBehaviorPopup.selectItem(at: index)
        }
        suffixField.stringValue = prefs.suffix
        folderPathField.stringValue = prefs.outputFolderPath.isEmpty ? "(none chosen)" : prefs.outputFolderPath
        keepMetadataCheckbox.state = prefs.keepMetadata ? .on : .off
        updateOutputControlsEnablement()
    }

    /// Suffix only matters when writing alongside the original or into a folder;
    /// in-place has no suffix at all. Folder picker only matters for "into a folder".
    private func updateOutputControlsEnablement() {
        let behavior = prefs.outputBehavior
        suffixField.isEnabled = behavior != .inplace
        folderPathField.isEnabled = behavior == .folder
        chooseFolderButton.isEnabled = behavior == .folder
    }

    /// Anything that changes the produced bytes, or where they land, invalidates the
    /// main window's previews and export marks.
    private func notifyChanged() {
        NotificationCenter.default.post(name: .squishPreferencesChanged, object: nil)
    }

    @objc private func defaultModeChanged() {
        prefs.defaultMode = SquishMode.allCases[defaultModePopup.indexOfSelectedItem]
    }

    @objc private func outputBehaviorChanged() {
        prefs.outputBehavior = OutputBehavior.allCases[outputBehaviorPopup.indexOfSelectedItem]
        updateOutputControlsEnablement()
        notifyChanged()
    }

    @objc private func suffixChanged() {
        prefs.suffix = suffixField.stringValue
        notifyChanged()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.urls.first, let self else { return }
            self.prefs.outputFolderPath = url.path
            self.folderPathField.stringValue = url.path
            self.notifyChanged()
        }
    }

    @objc private func keepMetadataChanged() {
        prefs.keepMetadata = keepMetadataCheckbox.state == .on
        notifyChanged()
    }

}

extension PreferencesWindowController: NSTextFieldDelegate {
    /// Commit text fields when focus leaves them too, not just on Return - otherwise
    /// a typed suffix silently fails to apply when the user just closes the window.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === suffixField {
            suffixChanged()
        }
    }
}

private extension NSBox {
    static func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
