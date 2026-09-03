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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Squish"
        window.center()
        window.setFrameAutosaveName("SquishMainWindow")
        // Enough room for five columns and a footer that never wraps.
        window.minSize = NSSize(width: 620, height: 360)
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

        for view in [headerStack, sliderStack, modeHint, dropContainer, progressBar,
                     actionSeparator, compressButton, footerHost] as [NSView] {
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

            modeHint.topAnchor.constraint(equalTo: sliderStack.bottomAnchor, constant: 6),
            modeHint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16 + 84 + 8),
            modeHint.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            dropContainer.topAnchor.constraint(equalTo: modeHint.bottomAnchor, constant: 12),
            dropContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dropContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dropContainer.bottomAnchor.constraint(equalTo: progressBar.topAnchor),

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

        tableView.addTableColumn(column(ColumnID.name, "Name", width: 260, min: 140))
        tableView.addTableColumn(column(ColumnID.original, "Original", width: 84, min: 70))
        tableView.addTableColumn(column(ColumnID.projected, "Projected", width: 84, min: 70))
        tableView.addTableColumn(column(ColumnID.saving, "Saving", width: 64, min: 56))
        tableView.addTableColumn(column(ColumnID.status, "Status", width: 150, min: 90))

        tableView.dataSource = self
        tableView.delegate = self
        tableView.actionDelegate = self
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnSelection = false
        tableView.rowHeight = 22
        // The Name column absorbs any spare width; the numeric columns stay put,
        // so the numbers never move when the window is resized.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.menu = makeContextMenu()
        tableView.target = self
        tableView.doubleAction = #selector(revealInFinder(_:))
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

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
        updateFooter()
    }

    private func clearExportMarks() {
        for item in items {
            item.exportError = nil
        }
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
        coordinator.refresh(items: items, settings: currentSettings)
        updateFooter()
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
    }

    @objc func clearList(_ sender: Any? = nil) {
        guard !items.isEmpty else { return }
        items.removeAll()
        coordinator.cancel()
        tableView.reloadData()
        updateListVisibility()
        updateFooter()
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
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(compress(_:)):
            return !items.isEmpty && compressButton.isEnabled
        case #selector(removeFromList(_:)), #selector(revealInFinder(_:)), #selector(trashOriginals(_:)):
            return !tableView.selectedRowIndexes.isEmpty
        case #selector(clearList(_:)):
            return !items.isEmpty
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
