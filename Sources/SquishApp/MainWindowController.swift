import AppKit
import SwiftUI

/// The app's one real window.
///
/// The shape of it: a mode picker across the top, one quality slider
/// under it, the file list filling the middle, then an action bar carrying the primary
/// Compress button and a Klip-style status footer. Dropping only ever *adds* - projections
/// are real encodes cached in the background, and nothing reaches its destination
/// until Compress is pressed.
final class MainWindowController: NSWindowController, NSMenuItemValidation {

    // MARK: - Controls

    private let modeControl = NSSegmentedControl(
        labels: SquishMode.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let compressButton = NSButton(title: "Compress", target: nil, action: nil)
    private let qualityCaption = NSTextField(labelWithString: "Quality")
    private let qualitySlider = NSSlider(value: 75, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityValue = NSTextField(labelWithString: "75%")
    private let modeHint = NSTextField(labelWithString: "")

    private let resizeCaption = NSTextField(labelWithString: "Resize")
    private let resizeKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthField = NSTextField(string: "2000")
    private let byLabel = NSTextField(labelWithString: "×")
    private let heightField = NSTextField(string: "2000")
    private let lockBadge = NSImageView()
    private let percentField = NSTextField(string: "50")
    private let percentLabel = NSTextField(labelWithString: "%")
    private let noEnlargeCheckbox = NSButton(checkboxWithTitle: "Don't enlarge", target: nil, action: nil)
    private let resizeHint = NSTextField(labelWithString: "")
    private let pixelGroup = NSStackView(frame: .zero)
    private let percentGroup = NSStackView(frame: .zero)

    private let outputCaption = NSTextField(labelWithString: "Output")
    private let outputBehaviorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let suffixCaption = NSTextField(labelWithString: "Suffix")
    private let suffixField = NSTextField(string: "-squish")
    private let chooseFolderButton = NSButton(title: "Choose\u{2026}", target: nil, action: nil)
    private let folderPathField = NSTextField(labelWithString: "")
    private let keepMetadataCheckbox = NSButton(checkboxWithTitle: "Keep metadata", target: nil, action: nil)
    private let outputHint = NSTextField(labelWithString: "")
    private let suffixGroup = NSStackView(frame: .zero)
    private let folderGroup = NSStackView(frame: .zero)

    private let splitView = NSSplitView(frame: .zero)
    private let comparisonPane = ComparisonView(frame: .zero)
    private let paneToggle = NSButton(frame: .zero)
    private let dropContainer = DropContainerView(frame: .zero)
    private let emptyState = EmptyStateView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let tableView = FileListTableView(frame: .zero)
    private let progressBar = NSProgressIndicator(frame: .zero)
    private let footerHost = NSHostingView(rootView: StatusFooter(stats: FooterStats()))

    // MARK: - State

    private var items: [FileItem] = []
    private let coordinator = PreviewCoordinator()
    private let prefs = Preferences.shared

    /// Session-only, by request: resets to 75 every launch and is never written to
    /// UserDefaults. The Settings window no longer has a quality control at all,
    /// so this slider is the single source of truth.
    private var quality = Preferences.defaultQuality
    /// Same treatment for the vlossless metric target - the same slider, relabelled.
    private var target = Preferences.defaultTarget

    private var mode: SquishMode = Preferences.shared.defaultMode

    /// Which of the two pixel fields the user typed in last. The other one follows the
    /// reference image's aspect ratio - the two are always locked together, by design:
    /// there is no form of this control that can stretch an image.
    private enum ResizeSide { case width, height }
    private var resizeLastEdited: ResizeSide = .width

    private enum ResizeKind: Int, CaseIterable {
        case off, pixels, percent
        var title: String {
            switch self {
            case .off: return "Off"
            case .pixels: return "Pixels"
            case .percent: return "Percent"
            }
        }
    }
    private var resizeKind: ResizeKind = .off

    /// Width the file list goes back to when the pane is expanded again. The list is
    /// the fixed column: it only has to hold a name and four numbers.
    private var rememberedListWidth: CGFloat = 500
    /// Once the user has opened or closed the pane by hand, the "collapse when a big
    /// batch lands" rule stops second-guessing them for the rest of the session.
    private var userChosePaneState = false

    private enum ColumnID {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let original = NSUserInterfaceItemIdentifier("original")
        static let projected = NSUserInterfaceItemIdentifier("projected")
        static let saving = NSUserInterfaceItemIdentifier("saving")
        static let status = NSUserInterfaceItemIdentifier("status")
    }

    private var valueColumnIndexes: IndexSet {
        IndexSet(1..<max(1, tableView.numberOfColumns))
    }

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Squish"
        window.center()
        window.setFrameAutosaveName("SquishMainWindow")
        // Enough room for the list's five columns beside a comparison pane that is
        // still worth looking at, plus a footer that never wraps.
        window.minSize = NSSize(width: 1100, height: 620)
        self.init(window: window)
        buildUI()
        applyMode(prefs.defaultMode, refresh: false)
        updateFooter()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: .squishPreferencesChanged,
            object: nil
        )

        coordinator.onChange = { [weak self] in
            self?.previewsChanged()
        }
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        modeControl.target = self
        modeControl.action = #selector(modeControlChanged)
        modeControl.segmentDistribution = .fillEqually
        modeControl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Deliberately styled and placed so it can never read as a fourth mode.
        // The mode control is a segmented picker at the top; this is the commit,
        // so it is large, accent-filled, carries a verb and a count, and lives
        // alone in its own bar at the bottom right - the standard macOS position
        // for a window's primary action.
        compressButton.bezelStyle = .push
        compressButton.controlSize = .large
        compressButton.bezelColor = .controlAccentColor
        compressButton.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                       accessibilityDescription: nil)
        compressButton.imagePosition = .imageLeading
        compressButton.imageHugsTitle = true
        compressButton.target = self
        compressButton.action = #selector(compress)
        // Cmd+Return, not bare Return: Return in a list means "open", and the button
        // is a commit, not a default the user might trip over.
        compressButton.keyEquivalent = "\r"
        compressButton.keyEquivalentModifierMask = [.command]
        compressButton.toolTip = "Write every projected file to its destination (⌘↩)"

        qualityCaption.font = .systemFont(ofSize: 12)
        qualityCaption.textColor = .labelColor
        qualityCaption.alignment = .right

        qualitySlider.target = self
        qualitySlider.action = #selector(qualitySliderChanged)
        qualitySlider.isContinuous = true
        qualitySlider.controlSize = .small

        qualityValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        qualityValue.alignment = .right

        modeHint.font = .systemFont(ofSize: 12)
        modeHint.textColor = .secondaryLabelColor
        modeHint.lineBreakMode = .byTruncatingTail

        buildResizeRow()
        buildOutputRow()
        buildTable()

        emptyState.onChooseFiles = { [weak self] in self?.presentAddFilesPanel() }
        dropContainer.onDrop = { [weak self] urls in self?.add(urls: urls) }

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        // Always laid out, faded out when idle, so showing progress never shifts
        // the list or the footer by a pixel.
        progressBar.alphaValue = 0

        buildComparisonPane()

        // The mode picker owns the whole header row now. Nothing sits beside it,
        // so no neighbouring control can be mistaken for a fourth segment.
        let headerStack = NSStackView(views: [modeControl])
        headerStack.orientation = .horizontal
        headerStack.spacing = 12
        headerStack.alignment = .centerY

        // A hairline rule separates the browsing area above from the commit below,
        // reinforcing that everything above is exploration and this is the action.
        let actionSeparator = NSBox()
        actionSeparator.boxType = .separator

        let sliderStack = NSStackView(views: [qualityCaption, qualitySlider, qualityValue])
        sliderStack.orientation = .horizontal
        sliderStack.spacing = 8
        sliderStack.alignment = .centerY

        let resizeStack = NSStackView(views: [resizeCaption, resizeKindPopup, pixelGroup,
                                              percentGroup, noEnlargeCheckbox, resizeHint])
        resizeStack.orientation = .horizontal
        resizeStack.spacing = 8
        resizeStack.alignment = .centerY

        let outputStack = NSStackView(views: [outputCaption, outputBehaviorPopup, suffixGroup,
                                              folderGroup, keepMetadataCheckbox, outputHint])
        outputStack.orientation = .horizontal
        outputStack.spacing = 8
        outputStack.alignment = .centerY

        for view in [headerStack, sliderStack, resizeStack, outputStack, modeHint, splitView, progressBar,
                     actionSeparator, paneToggle, compressButton, footerHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        for view in [emptyState, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            dropContainer.addSubview(view)
        }

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            headerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            sliderStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            sliderStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            sliderStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            // Fixed widths on both ends so relabelling "Quality" to "Visual target"
            // (or 9% to 100%) can never nudge the slider's track.
            qualityCaption.widthAnchor.constraint(equalToConstant: 84),
            qualityValue.widthAnchor.constraint(equalToConstant: 42),

            resizeStack.topAnchor.constraint(equalTo: sliderStack.bottomAnchor, constant: 10),
            resizeStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            resizeStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            resizeCaption.widthAnchor.constraint(equalToConstant: 84),

            outputStack.topAnchor.constraint(equalTo: resizeStack.bottomAnchor, constant: 10),
            outputStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            outputStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            outputCaption.widthAnchor.constraint(equalToConstant: 84),

            modeHint.topAnchor.constraint(equalTo: outputStack.bottomAnchor, constant: 8),
            modeHint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16 + 84 + 8),
            modeHint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            splitView.topAnchor.constraint(equalTo: modeHint.bottomAnchor, constant: 10),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: progressBar.topAnchor),

            scrollView.topAnchor.constraint(equalTo: dropContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: dropContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: dropContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: dropContainer.bottomAnchor),

            emptyState.topAnchor.constraint(equalTo: dropContainer.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: dropContainer.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: dropContainer.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: dropContainer.bottomAnchor),

            progressBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
            progressBar.bottomAnchor.constraint(equalTo: actionSeparator.topAnchor),

            // Action bar: hairline across the full width, primary action right-aligned
            // beneath it. Bottom-right is where macOS users look for a window's commit.
            actionSeparator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            actionSeparator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            paneToggle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            paneToggle.centerYAnchor.constraint(equalTo: compressButton.centerYAnchor),

            compressButton.topAnchor.constraint(equalTo: actionSeparator.bottomAnchor, constant: 10),
            compressButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            compressButton.bottomAnchor.constraint(equalTo: footerHost.topAnchor, constant: -10),

            footerHost.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footerHost.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footerHost.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        window?.initialFirstResponder = tableView
        updateListVisibility()
    }

    private func buildTable() {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = tableView

        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            column.minWidth = min
            return column
        }

        // Sized for the narrow left column of the split, not for a full-width window:
        // the name column is the flexible one and gives way first.
        // The inset style eats about 40pt of the column area, so these are sized to
        // fit inside the 400pt minimum list column with the Name column giving way.
        tableView.addTableColumn(column(ColumnID.name, "Name", width: 140, min: 80))
        tableView.addTableColumn(column(ColumnID.original, "Original", width: 66, min: 60))
        tableView.addTableColumn(column(ColumnID.projected, "Projected", width: 70, min: 64))
        tableView.addTableColumn(column(ColumnID.saving, "Saving", width: 52, min: 48))
        tableView.addTableColumn(column(ColumnID.status, "Status", width: 78, min: 70))

        tableView.dataSource = self
        tableView.delegate = self
        tableView.actionDelegate = self
        tableView.style = .inset
        // No zebra striping: past the last row it becomes wide grey bands of nothing,
        // which in a narrow column reads as clutter rather than as structure.
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.rowHeight = 22
        // The Name column absorbs any spare width; the numeric columns stay put,
        // so the numbers never move when the window is resized.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.menu = makeContextMenu()
        tableView.target = self
        tableView.doubleAction = #selector(compareSelected(_:))
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let compare = NSMenuItem(title: "Open Comparison Window…",
                                 action: #selector(compareSelected(_:)),
                                 keyEquivalent: "")
        compare.target = self
        menu.addItem(compare)

        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealInFinder(_:)), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        let remove = NSMenuItem(title: "Remove from List", action: #selector(removeFromList(_:)), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)

        // "Move to Trash" is the one item here that can destroy the user's work, so
        // it is pushed to the bottom behind a separator, spelled out in full, and
        // asks first. It must never sit next to "Remove from List".
        menu.addItem(.separator())

        let trash = NSMenuItem(title: "Move Original File to Trash…", action: #selector(trashOriginals(_:)), keyEquivalent: "")
        trash.target = self
        menu.addItem(trash)

        return menu
    }

    // MARK: - Resize

    /// One row, one promise: the two pixel fields are locked to the image's aspect
    /// ratio, always. Typing a width fills in the height and vice versa, so there is
    /// no way to stretch an image from here - and for a batch whose images are not all
    /// the same shape, the pair is sent as a box every image fits inside, which is the
    /// only reading of "2000 × 2000" that holds for a portrait and a landscape at once.
    private func buildResizeRow() {
        resizeCaption.font = .systemFont(ofSize: 12)
        resizeCaption.textColor = .labelColor
        resizeCaption.alignment = .right

        resizeKindPopup.removeAllItems()
        resizeKindPopup.addItems(withTitles: ResizeKind.allCases.map(\.title))
        resizeKindPopup.target = self
        resizeKindPopup.action = #selector(resizeKindChanged)
        resizeKindPopup.controlSize = .small
        resizeKindPopup.font = .systemFont(ofSize: 12)
        resizeKindPopup.toolTip = "Resize the pixels before compressing. Off keeps the original size."

        for field in [widthField, heightField, percentField] {
            field.target = self
            field.action = #selector(resizeFieldCommitted(_:))
            field.delegate = self
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.controlSize = .small
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }
        widthField.toolTip = "Output width in pixels. The height follows the aspect ratio."
        heightField.toolTip = "Output height in pixels. The width follows the aspect ratio."
        percentField.toolTip = "Scale both sides. Over 100% enlarges."

        for label in [byLabel, percentLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
        }

        lockBadge.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Aspect ratio locked")
        lockBadge.contentTintColor = .secondaryLabelColor
        lockBadge.toolTip = "Width and height are locked to the image's aspect ratio."

        noEnlargeCheckbox.target = self
        noEnlargeCheckbox.action = #selector(noEnlargeChanged)
        noEnlargeCheckbox.controlSize = .small
        noEnlargeCheckbox.font = .systemFont(ofSize: 12)
        noEnlargeCheckbox.toolTip = "Leave images that are already smaller than this untouched."

        resizeHint.font = .systemFont(ofSize: 11)
        resizeHint.textColor = .secondaryLabelColor
        resizeHint.lineBreakMode = .byTruncatingTail

        pixelGroup.setViews([widthField, byLabel, heightField, lockBadge], in: .leading)
        pixelGroup.orientation = .horizontal
        pixelGroup.spacing = 5
        pixelGroup.alignment = .centerY

        percentGroup.setViews([percentField, percentLabel], in: .leading)
        percentGroup.orientation = .horizontal
        percentGroup.spacing = 4
        percentGroup.alignment = .centerY

        loadResizeFromPreferences()
    }

    /// Resize is persisted, unlike quality: the Finder Quick Actions have no window to
    /// read it from, and "my exports are 2000px" is a property of the Mac, not of a
    /// session. The control for it still lives in exactly one place - this row.
    private func loadResizeFromPreferences() {
        if let spec = prefs.resize {
            noEnlargeCheckbox.state = spec.allowEnlarge ? .off : .on
            switch spec.target {
            case .box(let width, let height):
                resizeKind = .pixels
                widthField.stringValue = String(width)
                heightField.stringValue = String(height)
            case .width(let width):
                // Only reachable from a hand-edited defaults entry; the row always
                // writes a box. Show the side that was set and square off the other.
                resizeKind = .pixels
                widthField.stringValue = String(width)
                heightField.stringValue = String(width)
            case .height(let height):
                resizeKind = .pixels
                widthField.stringValue = String(height)
                heightField.stringValue = String(height)
            case .percent(let percent):
                resizeKind = .percent
                percentField.stringValue = percent == percent.rounded()
                    ? String(Int(percent))
                    : String(format: "%.2f", percent)
            }
        } else {
            resizeKind = .off
        }
        resizeKindPopup.selectItem(at: resizeKind.rawValue)
        updateResizeRowVisibility()
        updateResizeHint()
    }

    private func updateResizeRowVisibility() {
        pixelGroup.isHidden = resizeKind != .pixels
        percentGroup.isHidden = resizeKind != .percent
        noEnlargeCheckbox.isHidden = resizeKind == .off
        resizeHint.isHidden = resizeKind == .off
    }

    /// The image the two locked fields take their ratio from, and the one the hint
    /// line describes: the selected row, or the first row when nothing is selected.
    private var resizeReference: (width: Int, height: Int)? {
        (selectedItems.first ?? items.first)?.pixelSize
    }

    /// True when the list holds images of more than one shape, which is when the box
    /// reading of the two fields starts to matter and the hint has to say so.
    private var batchShapesDiffer: Bool {
        let sizes = items.prefix(60).compactMap(\.pixelSize)
        guard let first = sizes.first else { return false }
        let base = Double(first.width) / Double(first.height)
        return sizes.contains { abs(Double($0.width) / Double($0.height) - base) > 0.01 }
    }

    /// The spec the controls currently describe, or nil for Off.
    private var resizeFromControls: ResizeSpec? {
        let allowEnlarge = noEnlargeCheckbox.state != .on
        switch resizeKind {
        case .off:
            return nil
        case .pixels:
            let width = Int(widthField.stringValue) ?? 0
            let height = Int(heightField.stringValue) ?? 0
            guard width > 0, height > 0 else { return nil }
            return ResizeSpec(target: .box(width: min(width, ResizeSpec.maxSide),
                                           height: min(height, ResizeSpec.maxSide)),
                              allowEnlarge: allowEnlarge)
        case .percent:
            guard let percent = Double(percentField.stringValue), percent >= 1, percent <= 2000 else {
                return nil
            }
            return ResizeSpec(target: .percent(percent), allowEnlarge: allowEnlarge)
        }
    }

    private func updateResizeHint() {
        guard resizeKind != .off else {
            resizeHint.stringValue = ""
            return
        }
        guard let spec = resizeFromControls else {
            resizeHint.stringValue = "Enter a number."
            return
        }
        guard let source = resizeReference else {
            resizeHint.stringValue = "Aspect ratio kept."
            return
        }
        let out = spec.outputSize(forWidth: source.width, height: source.height)
        var text = "\(source.width)×\(source.height) → \(out.width)×\(out.height)"
        if out.width == source.width, out.height == source.height {
            text += " (unchanged)"
        }
        if items.count > 1, batchShapesDiffer {
            switch spec.target {
            case .box(let width, let height):
                text += " · the rest fit inside \(width)×\(height)"
            case .percent:
                text += " · every image at \(spec.description)"
            case .width, .height:
                break
            }
        }
        resizeHint.stringValue = text
    }

    /// Fills the field the user did not type in, from the reference image's ratio.
    private func syncLockedField() {
        guard resizeKind == .pixels, let source = resizeReference else { return }
        switch resizeLastEdited {
        case .width:
            guard let width = Int(widthField.stringValue), width > 0 else { return }
            let height = Double(width) * Double(source.height) / Double(source.width)
            heightField.stringValue = String(max(1, Int(height.rounded())))
        case .height:
            guard let height = Int(heightField.stringValue), height > 0 else { return }
            let width = Double(height) * Double(source.width) / Double(source.height)
            widthField.stringValue = String(max(1, Int(width.rounded())))
        }
    }

    /// Writes the row's value through to preferences (the single source of truth that
    /// `currentSettings` reads) and recomputes every preview against it.
    private func applyResize() {
        let spec = resizeFromControls
        // Return in a field and the field losing focus both commit, so the same value
        // can arrive twice; recomputing the whole list for it would be visible work.
        guard spec != prefs.resize else {
            updateResizeHint()
            return
        }
        prefs.resize = spec
        updateResizeHint()
        clearExportMarks()
        coordinator.refresh(items: items, settings: currentSettings)
        reloadValues()
        updateComparisonPane()
        updateFooter()
    }

    @objc private func resizeKindChanged() {
        let chosen = ResizeKind(rawValue: resizeKindPopup.indexOfSelectedItem) ?? .off
        guard chosen != resizeKind else { return }
        resizeKind = chosen
        // Switching into Pixels with nothing sensible in the fields seeds them from the
        // reference image, so the row never starts out describing a 1-pixel export.
        if resizeKind == .pixels {
            if (Int(widthField.stringValue) ?? 0) <= 0 { widthField.stringValue = "2000" }
            if (Int(heightField.stringValue) ?? 0) <= 0 { heightField.stringValue = "2000" }
            syncLockedField()
        }
        if resizeKind == .percent, (Double(percentField.stringValue) ?? 0) <= 0 {
            percentField.stringValue = "50"
        }
        updateResizeRowVisibility()
        applyResize()
    }

    @objc private func resizeFieldCommitted(_ sender: Any?) {
        if let field = sender as? NSTextField {
            if field === widthField { resizeLastEdited = .width }
            if field === heightField { resizeLastEdited = .height }
        }
        normalizeResizeFields()
        syncLockedField()
        applyResize()
    }

    /// Clamps what was typed to something the CLI will accept, and puts the clamped
    /// number back in the field so what is shown is what will happen.
    private func normalizeResizeFields() {
        for field in [widthField, heightField] {
            let digits = field.stringValue.filter(\.isNumber)
            let value = Int(digits) ?? 0
            if value > 0 {
                field.stringValue = String(min(value, ResizeSpec.maxSide))
            } else if resizeKind == .pixels {
                field.stringValue = "2000"
            }
        }
        if let percent = Double(percentField.stringValue.replacingOccurrences(of: ",", with: ".")),
           percent > 0 {
            let clamped = min(max(percent, 1), 2000)
            percentField.stringValue = clamped == clamped.rounded()
                ? String(Int(clamped))
                : String(format: "%.2f", clamped)
        } else if resizeKind == .percent {
            percentField.stringValue = "50"
        }
    }

    @objc private func noEnlargeChanged() {
        applyResize()
    }

    // MARK: - Mode & quality

    var currentMode: SquishMode { mode }

    private var currentSettings: EncodeSettings {
        prefs.encodeSettings(mode: mode, quality: quality, target: target)
    }

    @objc private func modeControlChanged() {
        let index = max(0, modeControl.selectedSegment)
        applyMode(SquishMode.allCases[index], refresh: true)
    }

    /// Single place that puts the window into a mode: segmented control, slider
    /// range and labels, hint line, footer, and the menu's checkmarks all follow.
    private func applyMode(_ newMode: SquishMode, refresh: Bool) {
        mode = newMode
        if let index = SquishMode.allCases.firstIndex(of: newMode) {
            modeControl.selectedSegment = index
        }

        if newMode.usesQuality {
            qualityCaption.stringValue = "Quality"
            qualitySlider.minValue = 1
            qualitySlider.maxValue = 100
            qualitySlider.doubleValue = Double(quality)
            qualitySlider.toolTip = "Encoder quality. Higher keeps more detail and makes a bigger file."
        } else {
            // For vlossless the encoder quality is *searched*, not chosen - so the
            // slider becomes the perceptual target that search aims at.
            qualityCaption.stringValue = "Visual target"
            qualitySlider.minValue = 55
            qualitySlider.maxValue = 100
            qualitySlider.doubleValue = Double(target)
            qualitySlider.toolTip = "Perceptual score the search must reach. 90 is visually lossless."
        }
        updateQualityValueLabel()

        switch newMode {
        case .jpeg:
            modeHint.stringValue = "mozjpeg, progressive and optimised. Always writes .jpg."
        case .webp:
            modeHint.stringValue = "cwebp. Always writes .webp."
        case .vlossless:
            modeHint.stringValue = "Searches for the smallest file that still scores at or above the target. Keeps the input format."
        }

        if refresh {
            clearExportMarks()
            coordinator.refresh(items: items, settings: currentSettings)
            reloadValues()
        }
        updateFooter()
    }

    private func updateQualityValueLabel() {
        qualityValue.stringValue = mode.usesQuality ? "\(quality)%" : "\(target)"
    }

    @objc private func qualitySliderChanged() {
        let value = Int(qualitySlider.doubleValue.rounded())
        if mode.usesQuality {
            guard value != quality else { return }
            quality = value
        } else {
            guard value != target else { return }
            target = value
        }
        updateQualityValueLabel()
        clearExportMarks()
        // Debounced: dragging the whole track spawns one recompute, not eighty.
        coordinator.scheduleRefresh(items: items, settings: currentSettings)
    }

    @objc private func preferencesChanged() {
        clearExportMarks()
        coordinator.refresh(items: items, settings: currentSettings)
        reloadValues()
        updateResizeHint()
        updateFooter()
    }

    private func clearExportMarks() {
        for item in items {
            item.exportError = nil
        }
    }

    // MARK: - Output

    /// Where the file lands and what it is called.
    ///
    /// This used to be three rows in Settings, which put the one thing people actually
    /// wanted to change - the `-squish` on every filename - two windows away from the
    /// Compress button, with no way to see what it would produce. Same rule as Resize:
    /// one control, in the window where the work happens, persisted through
    /// `Preferences` so the Finder Quick Actions and the CLI read the same choice.
    private func buildOutputRow() {
        outputCaption.font = .systemFont(ofSize: 12)
        outputCaption.textColor = .labelColor
        outputCaption.alignment = .right

        outputBehaviorPopup.removeAllItems()
        outputBehaviorPopup.addItems(withTitles: OutputBehavior.allCases.map(\.displayName))
        outputBehaviorPopup.target = self
        outputBehaviorPopup.action = #selector(outputBehaviorChanged)
        outputBehaviorPopup.controlSize = .small
        outputBehaviorPopup.font = .systemFont(ofSize: 12)
        outputBehaviorPopup.toolTip = "Where the compressed file is written."

        suffixCaption.font = .systemFont(ofSize: 12)
        suffixCaption.textColor = .secondaryLabelColor

        suffixField.target = self
        suffixField.action = #selector(suffixCommitted)
        suffixField.delegate = self
        suffixField.font = .systemFont(ofSize: 12)
        suffixField.controlSize = .small
        suffixField.placeholderString = "none"
        suffixField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        suffixField.toolTip = "Added to the end of each filename. Empty keeps the original name, "
            + "which needs an output folder - beside the original it would overwrite it."

        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseOutputFolder)
        chooseFolderButton.controlSize = .small
        chooseFolderButton.font = .systemFont(ofSize: 12)
        chooseFolderButton.toolTip = "Pick the folder every compressed file is written into."

        folderPathField.font = .systemFont(ofSize: 11)
        folderPathField.textColor = .secondaryLabelColor
        folderPathField.lineBreakMode = .byTruncatingMiddle
        folderPathField.widthAnchor.constraint(equalToConstant: 170).isActive = true

        keepMetadataCheckbox.target = self
        keepMetadataCheckbox.action = #selector(keepMetadataChanged)
        keepMetadataCheckbox.controlSize = .small
        keepMetadataCheckbox.font = .systemFont(ofSize: 12)
        keepMetadataCheckbox.toolTip = "Preserve EXIF and the source ICC profile. "
            + "Off strips metadata and converts to sRGB."

        outputHint.font = .systemFont(ofSize: 11)
        outputHint.textColor = .secondaryLabelColor
        outputHint.lineBreakMode = .byTruncatingMiddle

        suffixGroup.setViews([suffixCaption, suffixField], in: .leading)
        suffixGroup.orientation = .horizontal
        suffixGroup.spacing = 5
        suffixGroup.alignment = .centerY

        folderGroup.setViews([chooseFolderButton, folderPathField], in: .leading)
        folderGroup.orientation = .horizontal
        folderGroup.spacing = 6
        folderGroup.alignment = .centerY

        loadOutputFromPreferences()
    }

    private func loadOutputFromPreferences() {
        if let index = OutputBehavior.allCases.firstIndex(of: prefs.outputBehavior) {
            outputBehaviorPopup.selectItem(at: index)
        }
        suffixField.stringValue = prefs.suffix
        keepMetadataCheckbox.state = prefs.keepMetadata ? .on : .off
        updateFolderPathLabel()
        updateOutputRowVisibility()
        updateOutputHint()
    }

    private func updateFolderPathLabel() {
        let path = prefs.outputFolderPath
        folderPathField.stringValue = path.isEmpty
            ? "No folder chosen"
            : (path as NSString).abbreviatingWithTildeInPath
        folderPathField.toolTip = path.isEmpty ? nil : path
    }

    /// Hidden rather than dimmed, like the Resize row's two groups: a suffix means
    /// nothing when the original is being overwritten, and a folder means nothing
    /// unless that is where output goes.
    private func updateOutputRowVisibility() {
        let behavior = prefs.outputBehavior
        suffixGroup.isHidden = behavior == .inplace
        folderGroup.isHidden = behavior != .folder
    }

    /// Spells out the name the next Compress will write. "Everything comes out
    /// -squish" was only ever discoverable after the fact; this says it before.
    ///
    /// Reads the live field, not `prefs.suffix`, so the example keeps up while typing.
    private func updateOutputHint() {
        let example = items.first?.url
        let stem = example?.deletingPathExtension().lastPathComponent ?? "photo"
        let sourceExtension = (example?.pathExtension).flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let suffix = suffixField.stringValue
        let fileExtension: String
        switch mode {
        case .jpeg: fileExtension = "jpg"
        case .webp: fileExtension = "webp"
        // vlossless keeps the input format, so the only honest extension here is the
        // real one when a file is in the list.
        case .vlossless: fileExtension = sourceExtension ?? "png"
        }

        var warning = false
        switch prefs.outputBehavior {
        case .inplace:
            outputHint.stringValue = "Replaces \(stem).\(sourceExtension ?? fileExtension). The original is gone."
            warning = true
        case .alongside:
            if suffix.isEmpty {
                outputHint.stringValue = "With no suffix this overwrites the original. Add one, or write into a folder."
                warning = true
            } else {
                outputHint.stringValue = "\u{2192} \(stem)\(suffix).\(fileExtension)"
            }
        case .folder:
            let folder = prefs.outputFolderPath
            if folder.isEmpty {
                outputHint.stringValue = "No folder chosen yet - Compress has nowhere to write."
                warning = true
            } else {
                let name = (folder as NSString).lastPathComponent
                outputHint.stringValue = "\u{2192} \(name)/\(stem)\(suffix).\(fileExtension)"
            }
        }
        outputHint.textColor = warning ? .systemOrange : .secondaryLabelColor
    }

    @objc private func outputBehaviorChanged() {
        let chosen = OutputBehavior.allCases[outputBehaviorPopup.indexOfSelectedItem]
        guard chosen != prefs.outputBehavior else { return }
        prefs.outputBehavior = chosen
        updateOutputRowVisibility()
        // Choosing "into a folder" with none set is a dead end that only shows up at
        // Compress time, so ask for the folder now.
        if chosen == .folder, prefs.outputFolderPath.isEmpty {
            chooseOutputFolder()
        }
        outputChanged()
    }

    @objc private func suffixCommitted() {
        // Return and losing focus both commit, so the same value can arrive twice.
        guard suffixField.stringValue != prefs.suffix else {
            updateOutputHint()
            return
        }
        prefs.suffix = suffixField.stringValue
        outputChanged()
    }

    @objc private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Where should compressed files be written?"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.urls.first, let self else { return }
            self.prefs.outputFolderPath = url.path
            self.updateFolderPathLabel()
            self.outputChanged()
        }
    }

    @objc private func keepMetadataChanged() {
        prefs.keepMetadata = keepMetadataCheckbox.state == .on
        outputChanged()
    }

    /// Destination changes invalidate the export marks, and metadata changes invalidate
    /// the projected bytes as well. Both go through the one notification these controls
    /// posted when they lived in Settings, so there is still a single refresh path.
    private func outputChanged() {
        NotificationCenter.default.post(name: .squishPreferencesChanged, object: nil)
    }

    // MARK: - Adding files

    /// Entry point for drops (window, Dock icon, Open With), the file picker and the
    /// Services handlers. Everything adds; nothing compresses.
    func add(urls: [URL], forcedMode: SquishMode? = nil) {
        if let forcedMode, forcedMode != mode {
            applyMode(forcedMode, refresh: false)
        }

        let candidates = FileGatherer.imageFiles(from: urls)
        guard !candidates.isEmpty else {
            if !urls.isEmpty { NSSound.beep() }
            return
        }

        let known = Set(items.map(\.url.path))
        let fresh = candidates
            .filter { !known.contains($0.path) }
            .compactMap { FileItem(url: $0) }

        guard !fresh.isEmpty else {
            updateListVisibility()
            return
        }

        items.append(contentsOf: fresh)
        tableView.reloadData()
        updateListVisibility()
        autoAdjustPane(forItemCount: items.count)
        // Something has to be selected for the pane to have anything to show, and
        // selecting the first row is what the user would do next anyway.
        if tableView.selectedRowIndexes.isEmpty, !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        coordinator.refresh(items: items, settings: currentSettings)
        updateFooter()
        updateComparisonPane()
        updateResizeHint()
        window?.makeFirstResponder(tableView)
    }

    @objc func presentAddFilesPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose images to add to the list."
        panel.beginSheetModal(for: window ?? NSWindow()) { [weak self] response in
            guard response == .OK else { return }
            self?.add(urls: panel.urls)
        }
    }

    @objc func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders. Every image inside is added, including subfolders."
        panel.beginSheetModal(for: window ?? NSWindow()) { [weak self] response in
            guard response == .OK else { return }
            self?.add(urls: panel.urls)
        }
    }

    // MARK: - The action button

    @objc func compress(_ sender: Any? = nil) {
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }

        compressButton.isEnabled = false
        let settings = currentSettings
        Task { [weak self] in
            guard let self else { return }
            // Guarantees we only ever copy finished work: any row still calculating
            // (or debounced and not yet started) is completed first.
            await self.coordinator.refreshAndWait(items: self.items, settings: settings)
            self.performExport(settings: settings)
            self.compressButton.isEnabled = true
        }
    }

    private func performExport(settings: EncodeSettings) {
        let placement = prefs.placement
        var written = 0
        var failed = 0
        var bytesIn: Int64 = 0
        var bytesOut: Int64 = 0
        var firstError: String?

        for item in items {
            item.exportError = nil
            guard case .ready(let preview) = item.state else {
                if item.isFailed() { failed += 1 }
                continue
            }
            do {
                let destination = try Exporter.export(preview: preview,
                                                      from: item.url,
                                                      placement: placement)
                item.exported = (destination, settings.normalized)
                written += 1
                bytesIn += item.originalBytes
                bytesOut += preview.bytesOut
            } catch {
                failed += 1
                item.exportError = error.localizedDescription
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        reloadValues()
        updateFooter()

        guard written > 0 || failed > 0 else { return }

        if written > 0 {
            let noun = written == 1 ? "image" : "images"
            let saved = bytesIn > 0 ? Int((Double(bytesIn - bytesOut) / Double(bytesIn) * 100).rounded()) : 0
            let body = "\(written) \(noun) · \(ByteFormat.string(for: bytesIn)) → "
                     + "\(ByteFormat.string(for: bytesOut)) · saved \(saved)%"
            NotificationManager.notify(title: "Squish", body: body)
            NotificationManager.bounceDockIcon()
            NSApp.dockTile.badgeLabel = "\(written)"
        }

        if failed > 0, let firstError {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = failed == 1 ? "One file couldn't be written."
                                            : "\(failed) files couldn't be written."
            alert.informativeText = firstError
            alert.addButton(withTitle: "OK")
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }


    // MARK: - Comparison pane
    //
    // The list answers "how big will it be"; the pane answers "does it still look
    // right". Both come from the same PreviewCache entry, so the pane costs one image
    // decode and no extra encoding: the file it shows is the file Compress would write.

    private func buildComparisonPane() {
        // Side by side: a tall column suits both landscape and portrait images, where
        // a short full-width strip below the list suits neither.
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        // Deliberately NO autosaveName. NSSplitView's autosave competed with the
        // placement below, and because the first launch positions the divider before
        // the window has real bounds, it saved a list width of 0 - the pane covering
        // the whole window with no drop target - and restored that state on every
        // later launch. We own the position and persist the collapse flag ourselves.
        Self.discardLegacySplitAutosave()

        // NSSplitView positions its arranged subviews itself; their own contents keep
        // using Auto Layout as before.
        dropContainer.translatesAutoresizingMaskIntoConstraints = true
        comparisonPane.translatesAutoresizingMaskIntoConstraints = true
        splitView.addArrangedSubview(dropContainer)
        splitView.addArrangedSubview(comparisonPane)

        paneToggle.image = NSImage(systemSymbolName: "rectangle.split.2x1",
                                   accessibilityDescription: nil)
        paneToggle.title = "Comparison"
        paneToggle.imagePosition = .imageLeading
        paneToggle.bezelStyle = .rounded
        paneToggle.setButtonType(.pushOnPushOff)
        paneToggle.target = self
        paneToggle.action = #selector(toggleComparisonPane(_:))
        paneToggle.toolTip = "Show the selected image before and after compression (\u{21E7}\u{2318}C)"

        // Only the hidden flag here. Positioning needs real bounds, which do not
        // exist until the window has been laid out - see placeInitialDividerIfNeeded().
        comparisonPane.isHidden = prefs.comparisonPaneCollapsed
        paneToggle.state = prefs.comparisonPaneCollapsed ? .off : .on
    }

    /// Removes the divider geometry saved by builds that used `autosaveName`. Those
    /// entries can hold a zero-width list, which is unrecoverable through the UI.
    private static func discardLegacySplitAutosave() {
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames SquishMainSplitH")
    }

    private var hasPlacedDivider = false

    /// The divider can only be placed once the split view has a real width. Called
    /// from showWindow and again on the first resize, whichever gives real bounds first.
    private func placeInitialDividerIfNeeded() {
        guard !hasPlacedDivider else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        guard splitView.bounds.width > 0 else { return }
        hasPlacedDivider = true
        applyPaneCollapsed(prefs.comparisonPaneCollapsed, remember: false)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        placeInitialDividerIfNeeded()
    }

    /// The single place that opens or closes the pane. `remember` writes the choice to
    /// Preferences - this one genuinely should persist across launches.
    private func applyPaneCollapsed(_ collapsed: Bool, remember: Bool) {
        // NSSplitView positions are meaningless before the window has been laid out,
        // and a position set against zero bounds leaves the pane collapsed with the
        // divider stranded in the middle. Force the layout first, then place it.
        window?.contentView?.layoutSubtreeIfNeeded()

        // Positioning against zero bounds is what produced the zero-width list. Set
        // the flag and leave the geometry to placeInitialDividerIfNeeded().
        guard splitView.bounds.width > 0 else {
            comparisonPane.isHidden = collapsed
            paneToggle.state = collapsed ? .off : .on
            if remember {
                prefs.comparisonPaneCollapsed = collapsed
                userChosePaneState = true
            }
            return
        }

        if collapsed {
            let width = dropContainer.frame.width
            if width > 100 { rememberedListWidth = width }
            comparisonPane.isHidden = true
            // Push the divider to the trailing edge as well as hiding the pane, so the
            // list really does take the whole width and no ghost divider is left behind.
            if splitView.bounds.width > 0 {
                splitView.setPosition(splitView.bounds.width, ofDividerAt: 0)
            }
        } else {
            comparisonPane.isHidden = false
            let total = splitView.bounds.width
            if total > 0 {
                let list = min(max(rememberedListWidth, Self.listMinimumWidth),
                               max(total - Self.paneMinimumWidth, Self.listMinimumWidth))
                splitView.setPosition(list, ofDividerAt: 0)
            }
        }
        splitView.adjustSubviews()
        paneToggle.state = collapsed ? .off : .on
        if remember {
            prefs.comparisonPaneCollapsed = collapsed
            userChosePaneState = true
        }
        updateComparisonPane()
    }

    private var isPaneCollapsed: Bool { comparisonPane.isHidden }

    @objc func toggleComparisonPane(_ sender: Any? = nil) {
        applyPaneCollapsed(!isPaneCollapsed, remember: true)
    }

    /// Feeds the pane the current selection. Cheap and idempotent: an unchanged
    /// (file, settings) pair does no work at all, and a collapsed pane does none either.
    private func updateComparisonPane() {
        guard !isPaneCollapsed else {
            comparisonPane.clear(message: "")
            return
        }
        guard let item = selectedItems.first else {
            comparisonPane.clear(message: items.isEmpty
                                 ? "Add an image to compare it before and after compression."
                                 : "Select a file to compare it with its compressed result.")
            return
        }
        comparisonPane.show(item: item, settings: currentSettings)
    }

    /// A single image wants the pane open; a batch of forty wants the list. Applied
    /// only until the user makes their own choice, which then sticks.
    private func autoAdjustPane(forItemCount count: Int) {
        guard !userChosePaneState, count > 0 else { return }
        applyPaneCollapsed(count > Self.paneAutoCollapseThreshold, remember: false)
    }

    /// Up to three files: the pane is worth the room. Four or more reads as a batch.
    private static let paneAutoCollapseThreshold = 3
    /// A name plus four numeric columns, and no more - narrow enough to leave the
    /// pane the lion's share, wide enough that the Status column is never clipped.
    static let listMinimumWidth: CGFloat = 400
    /// Below this a comparison is not worth making.
    static let paneMinimumWidth: CGFloat = 380

    // MARK: - List commands

    private var selectedItems: [FileItem] {
        tableView.selectedRowIndexes.compactMap { index in
            items.indices.contains(index) ? items[index] : nil
        }
    }

    @objc func removeFromList(_ sender: Any? = nil) {
        let indexes = tableView.selectedRowIndexes
        guard !indexes.isEmpty else { return }
        // Removing a row is a list operation and nothing else. The file on disk is
        // never touched here - "Move Original File to Trash…" is the only thing
        // that deletes, and it asks first.
        for index in indexes.sorted(by: >) where items.indices.contains(index) {
            items.remove(at: index)
        }
        tableView.reloadData()
        if let first = indexes.first, !items.isEmpty {
            let next = min(first, items.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
        updateListVisibility()
        updateFooter()
        updateComparisonPane()
    }

    @objc func clearList(_ sender: Any? = nil) {
        guard !items.isEmpty else { return }
        items.removeAll()
        coordinator.cancel()
        tableView.reloadData()
        updateListVisibility()
        updateFooter()
        updateComparisonPane()
        NSApp.dockTile.badgeLabel = nil
    }

    @objc func revealInFinder(_ sender: Any? = nil) {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        // Once a row has been exported, "reveal" means the result the user just made,
        // not the source they started from.
        let urls = targets.map { $0.exported?.url ?? $0.url }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Opens the before/after window for the row that was double-clicked, or for the
    /// first selected row when it comes from a menu. One window per file.
    @objc func compareSelected(_ sender: Any? = nil) {
        // A double-click in the empty space below the last row must not open the
        // window for whatever happened to be selected.
        if sender as AnyObject? === tableView, tableView.clickedRow < 0 { return }
        guard let item = selectedItems.first else { NSSound.beep(); return }
        CompareWindowController.present(item: item, settings: currentSettings)
    }

    @objc func trashOriginals(_ sender: Any? = nil) {
        let targets = selectedItems
        guard !targets.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = targets.count == 1
            ? "Move “\(targets[0].url.lastPathComponent)” to the Trash?"
            : "Move \(targets.count) original files to the Trash?"
        alert.informativeText = "This moves the original file, not just the list entry. "
                              + "You can put it back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        let handle: @MainActor (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            for item in targets {
                try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            }
            let doomed = Set(targets.map(\.id))
            self.items.removeAll { doomed.contains($0.id) }
            self.tableView.reloadData()
            self.updateListVisibility()
            self.updateFooter()
        }

        if let window {
            alert.beginSheetModal(for: window) { handle($0) }
        } else {
            handle(alert.runModal())
        }
    }

    @objc func selectModeMenuItem(_ sender: NSMenuItem) {
        guard SquishMode.allCases.indices.contains(sender.tag) else { return }
        applyMode(SquishMode.allCases[sender.tag], refresh: true)
    }

    // MARK: - Refreshing the chrome

    private func previewsChanged() {
        reloadValues()
        updateFooter()
        updateProgress()
        // The pane and any open comparison window re-resolve their compressed side
        // against the settings this window is now on - the same nudge that repaints
        // the projected sizes, so the picture and the numbers can never disagree.
        updateComparisonPane()
        CompareWindowController.mainWindowDidUpdate(settings: currentSettings)
    }

    /// Reloads only the value columns, leaving the Name column (and the selection,
    /// and the scroll position) undisturbed - so numbers landing one at a time never
    /// make the list flicker or jump.
    private func reloadValues() {
        guard tableView.numberOfRows == items.count, !items.isEmpty else {
            tableView.reloadData()
            return
        }
        tableView.reloadData(forRowIndexes: IndexSet(0..<items.count),
                             columnIndexes: valueColumnIndexes)
    }

    private func updateProgress() {
        let total = coordinator.totalCount
        if total > 0 {
            progressBar.maxValue = Double(total)
            progressBar.doubleValue = Double(coordinator.completedCount)
            if progressBar.alphaValue != 1 {
                progressBar.animator().alphaValue = 1
            }
        } else if progressBar.alphaValue != 0 {
            progressBar.animator().alphaValue = 0
        }
    }

    private func updateListVisibility() {
        let empty = items.isEmpty
        emptyState.isHidden = !empty
        scrollView.isHidden = empty
        updateCompressButtonTitle()
    }

    /// A verb plus a count. "Compress 3 Images" cannot be misread as the name of a
    /// mode, which a bare "Compress" sitting near a segmented picker still could.
    private func updateCompressButtonTitle() {
        switch items.count {
        case 0:  compressButton.title = "Compress"
        case 1:  compressButton.title = "Compress 1 Image"
        default: compressButton.title = "Compress \(items.count) Images"
        }
    }

    private func updateFooter() {
        var stats = FooterStats()
        stats.fileCount = items.count
        stats.selectedCount = tableView.selectedRowIndexes.count
        stats.mode = mode
        for item in items {
            stats.totalOriginal += item.originalBytes
            if let projected = item.projectedBytes {
                stats.totalProjected += projected
                stats.projectedCount += 1
            }
            if item.isFailed() || item.exportError != nil {
                stats.failedCount += 1
            }
        }
        stats.busyCompleted = coordinator.completedCount
        stats.busyTotal = coordinator.totalCount
        footerHost.rootView = StatusFooter(stats: stats)
        // The output hint names the first file in the list and the mode's extension,
        // so it goes stale on exactly the changes that reach here: adds, removals,
        // mode switches, preference changes and finished exports.
        updateOutputHint()
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(compress(_:)):
            return !items.isEmpty && compressButton.isEnabled
        case #selector(removeFromList(_:)), #selector(revealInFinder(_:)), #selector(trashOriginals(_:)):
            return !tableView.selectedRowIndexes.isEmpty
        case #selector(compareSelected(_:)):
            // Exactly one row can be compared at a time; a multi-selection compares
            // the first of them, and no selection means nothing to compare.
            return !tableView.selectedRowIndexes.isEmpty
        case #selector(clearList(_:)):
            return !items.isEmpty
        case #selector(toggleComparisonPane(_:)):
            menuItem.title = isPaneCollapsed ? "Show Comparison Pane" : "Hide Comparison Pane"
            menuItem.state = isPaneCollapsed ? .off : .on
            return true
        case #selector(selectModeMenuItem(_:)):
            menuItem.state = (SquishMode.allCases.indices.contains(menuItem.tag)
                              && SquishMode.allCases[menuItem.tag] == mode) ? .on : .off
            return true
        default:
            return true
        }
    }

    /// Called by the app delegate on quit.
    func cancelPendingWork() {
        coordinator.cancel()
    }
}

// MARK: - Table data

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, items.indices.contains(row) else { return nil }
        let item = items[row]
        let settings = currentSettings

        if identifier == ColumnID.status {
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? StatusCellView)
                ?? {
                    let view = StatusCellView(frame: .zero)
                    view.identifier = identifier
                    return view
                }()
            let tint: NSColor
            if item.exportError != nil || item.isFailed() {
                tint = .systemRed
            } else if item.isBusy {
                tint = .secondaryLabelColor
            } else if item.exported?.settings == settings.normalized {
                tint = .systemGreen
            } else {
                tint = .secondaryLabelColor
            }
            cell.configure(text: item.statusText(for: settings), busy: item.isBusy, tint: tint)
            return cell
        }

        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeTextCell(identifier: identifier)
        guard let field = cell.textField else { return cell }

        switch identifier {
        case ColumnID.name:
            field.stringValue = item.url.lastPathComponent
            field.textColor = .labelColor
            cell.toolTip = item.url.path
        case ColumnID.original:
            field.stringValue = ByteFormat.string(for: item.originalBytes)
            field.textColor = .secondaryLabelColor
        case ColumnID.projected:
            field.stringValue = item.projectedBytes.map(ByteFormat.string) ?? "—"
            field.textColor = item.projectedBytes == nil ? .secondaryLabelColor : .labelColor
        case ColumnID.saving:
            if let saved = item.savedPercent {
                field.stringValue = String(format: "%.0f%%", saved)
                field.textColor = saved > 0 ? .secondaryLabelColor : .systemOrange
            } else {
                field.stringValue = "—"
                field.textColor = .secondaryLabelColor
            }
        default:
            field.stringValue = ""
        }
        return cell
    }

    private func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let field = NSTextField(labelWithString: "")
        let numeric = identifier != ColumnID.name
        field.font = numeric
            ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 11)
        field.alignment = numeric ? .right : .left
        field.lineBreakMode = identifier == ColumnID.name ? .byTruncatingMiddle : .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
        // The hint describes the selected image, so it moves with the selection. The
        // two locked fields deliberately do not: clicking a row must not quietly
        // rewrite the size the user typed, and the box they form already holds for
        // every shape in the list.
        updateResizeHint()
        // Single selection drives the pane, so arrow-keying down the list walks the
        // comparison along with it.
        updateComparisonPane()
    }
}

// MARK: - Resize fields

extension MainWindowController: NSTextFieldDelegate {

    /// Live, while typing: the hints keep up, but nothing is recomputed yet.
    func controlTextDidChange(_ notification: Notification) {
        updateResizeHint()
        updateOutputHint()
    }

    /// Commit when focus leaves the field too, not only on Return - otherwise a typed
    /// size or suffix silently fails to apply when the user goes straight to Compress.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === suffixField {
            suffixCommitted()
            return
        }
        guard field === widthField || field === heightField || field === percentField else { return }
        resizeFieldCommitted(field)
    }
}

// MARK: - Keyboard removal

extension MainWindowController: FileListTableViewDelegate {
    func fileListRemoveSelection() {
        removeFromList(nil)
    }
}

// MARK: - Context menu

extension MainWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // FileListTableView has already reconciled the clicked row with the
        // selection, so the count here is exactly what the items will act on.
        let count = tableView.selectedRowIndexes.count
        for item in menu.items {
            switch item.action {
            case #selector(removeFromList(_:)):
                item.title = count > 1 ? "Remove \(count) Items from List" : "Remove from List"
            case #selector(trashOriginals(_:)):
                item.title = count > 1 ? "Move \(count) Original Files to Trash…" : "Move Original File to Trash…"
            case #selector(revealInFinder(_:)):
                item.title = count > 1 ? "Reveal \(count) Items in Finder" : "Reveal in Finder"
            default:
                break
            }
        }
    }
}

// MARK: - Split view

extension MainWindowController: @MainActor NSSplitViewDelegate {

    /// Only the pane collapses; the file list is the window.
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === comparisonPane
    }

    func splitView(_ splitView: NSSplitView,
                   shouldCollapseSubview subview: NSView,
                   forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        subview === comparisonPane
    }

    /// Never let the list column shrink below its five columns…
    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, MainWindowController.listMinimumWidth)
    }

    /// …or the pane become too narrow to compare anything in.
    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition,
            max(splitView.bounds.width - MainWindowController.paneMinimumWidth,
                MainWindowController.listMinimumWidth))
    }

    /// The pane is the flexible column: widening the window makes the image bigger,
    /// not the table. The list keeps the width the user gave it.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === comparisonPane
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if !comparisonPane.isHidden, dropContainer.frame.width > 100 {
            rememberedListWidth = dropContainer.frame.width
        }
    }
}

// MARK: - Persisted pane state

extension Preferences {
    /// Whether the main window's comparison pane is closed. Unlike the quality
    /// slider, this is a layout choice and should survive a relaunch.
    var comparisonPaneCollapsed: Bool {
        get { defaults.bool(forKey: "comparisonPaneCollapsed") }
        set { defaults.set(newValue, forKey: "comparisonPaneCollapsed") }
    }
}
