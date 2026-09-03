import AppKit

/// Small preferences window. Every control reads/writes straight through to
/// Preferences.shared (UserDefaults suite com.fxreza.squish) - no separate
/// "Apply"/"OK", changes take effect immediately, matching a typical macOS
/// utility's prefs window.
final class PreferencesWindowController: NSWindowController {

    private let prefs = Preferences.shared

    private let defaultModePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let qualityWebSlider = NSSlider(value: 84, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityWebField = NSTextField(labelWithString: "")

    private let qualityWebpSlider = NSSlider(value: 82, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityWebpField = NSTextField(labelWithString: "")

    private let vlosslessTargetSlider = NSSlider(value: 90, minValue: 55, maxValue: 100, target: nil, action: nil)
    private let vlosslessTargetField = NSTextField(labelWithString: "")

    private let outputBehaviorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let suffixField = NSTextField(string: "-squish")
    private let folderPathField = NSTextField(labelWithString: "")
    private let chooseFolderButton = NSButton(title: "Choose…", target: nil, action: nil)

    private let keepMetadataCheckbox = NSButton(checkboxWithTitle: "Keep metadata (EXIF + ICC)", target: nil, action: nil)

    private let maxDimensionCheckbox = NSButton(checkboxWithTitle: "Limit long edge to", target: nil, action: nil)
    private let maxDimensionField = NSTextField(string: "2048")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Squish Preferences"
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
        labelField.widthAnchor.constraint(equalToConstant: 150).isActive = true

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

        qualityWebSlider.target = self
        qualityWebSlider.action = #selector(qualityWebChanged)
        qualityWebSlider.isContinuous = true
        qualityWebField.isEditable = false
        qualityWebField.isBordered = false
        qualityWebField.drawsBackground = false
        qualityWebField.widthAnchor.constraint(equalToConstant: 30).isActive = true

        qualityWebpSlider.target = self
        qualityWebpSlider.action = #selector(qualityWebpChanged)
        qualityWebpSlider.isContinuous = true
        qualityWebpField.isEditable = false
        qualityWebpField.isBordered = false
        qualityWebpField.drawsBackground = false
        qualityWebpField.widthAnchor.constraint(equalToConstant: 30).isActive = true

        vlosslessTargetSlider.target = self
        vlosslessTargetSlider.action = #selector(vlosslessTargetChanged)
        vlosslessTargetSlider.isContinuous = true
        vlosslessTargetField.isEditable = false
        vlosslessTargetField.isBordered = false
        vlosslessTargetField.drawsBackground = false
        vlosslessTargetField.widthAnchor.constraint(equalToConstant: 30).isActive = true

        outputBehaviorPopup.removeAllItems()
        outputBehaviorPopup.addItems(withTitles: OutputBehavior.allCases.map(\.displayName))
        outputBehaviorPopup.target = self
        outputBehaviorPopup.action = #selector(outputBehaviorChanged)

        suffixField.target = self
        suffixField.action = #selector(suffixChanged)
        suffixField.widthAnchor.constraint(equalToConstant: 100).isActive = true

        folderPathField.isEditable = false
        folderPathField.isBordered = true
        folderPathField.font = .systemFont(ofSize: 11)
        folderPathField.lineBreakMode = .byTruncatingMiddle
        folderPathField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder)

        keepMetadataCheckbox.target = self
        keepMetadataCheckbox.action = #selector(keepMetadataChanged)

        maxDimensionCheckbox.target = self
        maxDimensionCheckbox.action = #selector(maxDimensionEnabledChanged)
        maxDimensionField.target = self
        maxDimensionField.action = #selector(maxDimensionChanged)
        maxDimensionField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let pxLabel = NSTextField(labelWithString: "px")

        let outputFolderRow = NSStackView(views: [folderPathField, chooseFolderButton])
        outputFolderRow.orientation = .horizontal
        outputFolderRow.spacing = 6

        let maxDimRow = NSStackView(views: [maxDimensionField, pxLabel])
        maxDimRow.orientation = .horizontal
        maxDimRow.spacing = 4

        let rows: [NSView] = [
            row(label: "Default mode:", control: defaultModePopup),
            NSBox.separatorLine(),
            row(label: "Web quality:", control: qualityWebSlider, trailing: qualityWebField),
            row(label: "WebP quality:", control: qualityWebpSlider, trailing: qualityWebpField),
            row(label: "Vis. lossless target:", control: vlosslessTargetSlider, trailing: vlosslessTargetField),
            NSBox.separatorLine(),
            row(label: "Output:", control: outputBehaviorPopup),
            row(label: "Suffix:", control: suffixField),
            row(label: "Output folder:", control: outputFolderRow),
            NSBox.separatorLine(),
            row(label: "", control: keepMetadataCheckbox),
            row(label: "", control: maxDimensionCheckbox, trailing: maxDimRow),
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
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func loadFromPreferences() {
        if let idx = SquishMode.allCases.firstIndex(of: prefs.defaultMode) {
            defaultModePopup.selectItem(at: idx)
        }
        qualityWebSlider.doubleValue = Double(prefs.qualityWeb)
        qualityWebField.stringValue = "\(prefs.qualityWeb)"

        qualityWebpSlider.doubleValue = Double(prefs.qualityWebp)
        qualityWebpField.stringValue = "\(prefs.qualityWebp)"

        vlosslessTargetSlider.doubleValue = Double(prefs.vlosslessTarget)
        vlosslessTargetField.stringValue = "\(prefs.vlosslessTarget)"

        if let idx = OutputBehavior.allCases.firstIndex(of: prefs.outputBehavior) {
            outputBehaviorPopup.selectItem(at: idx)
        }
        suffixField.stringValue = prefs.suffix
        folderPathField.stringValue = prefs.outputFolderPath.isEmpty ? "(none chosen)" : prefs.outputFolderPath

        keepMetadataCheckbox.state = prefs.keepMetadata ? .on : .off

        maxDimensionCheckbox.state = prefs.maxDimensionEnabled ? .on : .off
        maxDimensionField.stringValue = "\(prefs.maxDimension)"
        maxDimensionField.isEnabled = prefs.maxDimensionEnabled
    }

    @objc private func defaultModeChanged() {
        prefs.defaultMode = SquishMode.allCases[defaultModePopup.indexOfSelectedItem]
    }

    @objc private func qualityWebChanged() {
        let v = Int(qualityWebSlider.doubleValue.rounded())
        prefs.qualityWeb = v
        qualityWebField.stringValue = "\(v)"
    }

    @objc private func qualityWebpChanged() {
        let v = Int(qualityWebpSlider.doubleValue.rounded())
        prefs.qualityWebp = v
        qualityWebpField.stringValue = "\(v)"
    }

    @objc private func vlosslessTargetChanged() {
        let v = Int(vlosslessTargetSlider.doubleValue.rounded())
        prefs.vlosslessTarget = v
        vlosslessTargetField.stringValue = "\(v)"
    }

    @objc private func outputBehaviorChanged() {
        prefs.outputBehavior = OutputBehavior.allCases[outputBehaviorPopup.indexOfSelectedItem]
    }

    @objc private func suffixChanged() {
        prefs.suffix = suffixField.stringValue
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.urls.first, let self else { return }
            self.prefs.outputFolderPath = url.path
            self.folderPathField.stringValue = url.path
        }
    }

    @objc private func keepMetadataChanged() {
        prefs.keepMetadata = keepMetadataCheckbox.state == .on
    }

    @objc private func maxDimensionEnabledChanged() {
        let enabled = maxDimensionCheckbox.state == .on
        prefs.maxDimensionEnabled = enabled
        maxDimensionField.isEnabled = enabled
    }

    @objc private func maxDimensionChanged() {
        if let v = Int(maxDimensionField.stringValue) {
            prefs.maxDimension = v
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
