import AppKit

/// The whole before/after surface as one reusable component: the split image, the
/// caption chips, the `[- 101% +]` pill and the loading/error states.
///
/// It is used twice - as the pane inside the main window and as the standalone
/// comparison window - so the two can never drift apart in behaviour or in looks.
/// It owns no policy: whoever embeds it says which file and which settings to show,
/// and calls again when either changes.
///
/// Nothing here ever blocks the main thread. Decoding runs off-actor, the compressed
/// side is resolved from `PreviewCache` (or waited for, or encoded) inside a task that
/// is cancelled the moment the selection moves on, so clicking down a 40-file list
/// stays instant.
@MainActor
final class ComparisonView: NSView {

    // MARK: - Views

    private let compareView = CompareImageView(frame: .zero)
    private let zoomBar = NSVisualEffectView(frame: .zero)
    private let minusButton = NSButton(frame: .zero)
    private let plusButton = NSButton(frame: .zero)
    private let percentButton = NSButton(frame: .zero)
    private let statusOverlay = NSVisualEffectView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator(frame: .zero)
    private let placeholder = NSTextField(labelWithString: "")

    // MARK: - State

    private(set) var item: FileItem?
    private var settings: EncodeSettings?
    private var loadedOriginal: LoadedImage?
    private var shownKey: PreviewKey?
    private var loadingKey: PreviewKey?
    private var loadTask: Task<Void, Never>?

    /// Called whenever the subtitle-worthy description of the result changes, so a
    /// host window can put it in its title bar. nil when there is nothing to show.
    var onDescriptionChanged: ((String?) -> Void)?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
    }

    private func buildUI() {
        wantsLayer = true

        compareView.translatesAutoresizingMaskIntoConstraints = false
        compareView.onZoomChanged = { [weak self] zoom in self?.updateZoomLabel(zoom) }
        compareView.toolTip = "Drag the handle to compare. Pinch to zoom, two fingers to pan, "
                            + "double-click to switch between fit and 100%."
        addSubview(compareView)

        buildZoomBar()
        addSubview(zoomBar)

        buildStatusOverlay()
        addSubview(statusOverlay)

        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        NSLayoutConstraint.activate([
            compareView.leadingAnchor.constraint(equalTo: leadingAnchor),
            compareView.trailingAnchor.constraint(equalTo: trailingAnchor),
            compareView.topAnchor.constraint(equalTo: topAnchor),
            compareView.bottomAnchor.constraint(equalTo: bottomAnchor),

            zoomBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            zoomBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            zoomBar.heightAnchor.constraint(equalToConstant: 30),

            statusOverlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusOverlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusOverlay.heightAnchor.constraint(equalToConstant: 34),

            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        showPlaceholder("Select a file to compare it with its compressed result.")
    }

    /// `[ - ]  101%  [ + ]` - minus left, live percentage in the middle, plus right,
    /// and deliberately nothing else.
    private func buildZoomBar() {
        zoomBar.translatesAutoresizingMaskIntoConstraints = false
        zoomBar.material = .hudWindow
        zoomBar.blendingMode = .withinWindow
        zoomBar.state = .active
        zoomBar.wantsLayer = true
        zoomBar.layer?.cornerRadius = 15
        zoomBar.layer?.cornerCurve = .continuous
        zoomBar.layer?.borderWidth = 1
        zoomBar.layer?.borderColor = NSColor.separatorColor.cgColor
        zoomBar.layer?.masksToBounds = true
        zoomBar.maskImage = .roundedMask(cornerRadius: 15)

        configureStepper(minusButton, symbol: "minus", tip: "Zoom out")
        minusButton.target = self
        minusButton.action = #selector(zoomOut)

        configureStepper(plusButton, symbol: "plus", tip: "Zoom in")
        plusButton.target = self
        plusButton.action = #selector(zoomIn)

        percentButton.isBordered = false
        percentButton.bezelStyle = .inline
        percentButton.setButtonType(.momentaryChange)
        percentButton.alignment = .center
        percentButton.toolTip = "Click to reset the zoom to 100%"
        percentButton.target = self
        percentButton.action = #selector(resetZoom)
        percentButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [minusButton, percentButton, plusButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        zoomBar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: zoomBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: zoomBar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: zoomBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: zoomBar.bottomAnchor),
            // Fixed, so the pill does not breathe as the number changes width.
            percentButton.widthAnchor.constraint(equalToConstant: 54)
        ])
        updateZoomLabel(1)
    }

    private func configureStepper(_ button: NSButton, symbol: String, tip: String) {
        button.isBordered = false
        button.bezelStyle = .inline
        button.setButtonType(.momentaryChange)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func buildStatusOverlay() {
        statusOverlay.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.material = .hudWindow
        statusOverlay.blendingMode = .withinWindow
        statusOverlay.state = .active
        statusOverlay.wantsLayer = true
        statusOverlay.layer?.cornerRadius = 8
        statusOverlay.layer?.cornerCurve = .continuous
        statusOverlay.layer?.masksToBounds = true
        statusOverlay.maskImage = .roundedMask(cornerRadius: 8)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .labelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, statusLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: statusOverlay.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: statusOverlay.trailingAnchor),
            stack.topAnchor.constraint(equalTo: statusOverlay.topAnchor),
            stack.bottomAnchor.constraint(equalTo: statusOverlay.bottomAnchor)
        ])
        statusOverlay.isHidden = true
    }

    // MARK: - Public API

    /// Shows `item` at `settings`. Safe to call as often as you like: an unchanged
    /// (file, settings) pair is a no-op, so a selection change and a preview landing
    /// can both funnel through here without restarting work.
    func show(item newItem: FileItem?, settings newSettings: EncodeSettings) {
        let normalized = newSettings.normalized

        guard let newItem else {
            clear(message: "Select a file to compare it with its compressed result.")
            return
        }

        if newItem.id != item?.id {
            // A different file: everything about the old one goes, including the zoom,
            // so a fresh image always arrives fitted rather than inheriting a 400% pan.
            loadTask?.cancel()
            loadTask = nil
            loadingKey = nil
            shownKey = nil
            loadedOriginal = nil
            item = newItem
            settings = normalized
            compareView.reset()
            compareView.isHidden = true
            placeholder.isHidden = true
            zoomBar.isHidden = false
            onDescriptionChanged?(nil)
            reload(force: true)
            return
        }

        settings = normalized
        reload(force: false)
    }

    func clear(message: String) {
        loadTask?.cancel()
        loadTask = nil
        loadingKey = nil
        shownKey = nil
        loadedOriginal = nil
        item = nil
        settings = nil
        compareView.reset()
        showPlaceholder(message)
        onDescriptionChanged?(nil)
    }

    /// True when the pane is showing something worth the space it takes.
    var hasContent: Bool { item != nil }

    // MARK: - Zoom bar

    @objc private func zoomIn() { compareView.stepZoom(1.25) }
    @objc private func zoomOut() { compareView.stepZoom(1 / 1.25) }
    @objc private func resetZoom() { compareView.zoomToActualSize() }

    private func updateZoomLabel(_ zoom: CGFloat) {
        let percent = Int((zoom * 100).rounded())
        // Monospaced digits, so the number cannot jitter the pill while pinching.
        percentButton.attributedTitle = NSAttributedString(
            string: "\(percent)%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    return style
                }()
            ]
        )
        minusButton.isEnabled = zoom > CompareImageView.minZoomFloor + 0.0001
        plusButton.isEnabled = zoom < CompareImageView.maxZoom - 0.0001
    }

    // MARK: - Loading

    private func reload(force: Bool) {
        guard let item, let settings else { return }
        let key = item.key(for: settings)
        if !force, key == shownKey || (key == loadingKey && loadTask != nil) { return }

        loadingKey = key
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(item: item, key: key, force: force)
            if self.loadingKey == key {
                self.loadingKey = nil
                self.loadTask = nil
            }
        }
    }

    private func performLoad(item: FileItem, key: PreviewKey, force: Bool) async {
        if force || loadedOriginal == nil {
            showStatus("Loading image…", busy: true)
            do {
                let original = try await ComparisonImageLoader.load(url: item.url)
                guard !Task.isCancelled, self.item?.id == item.id else { return }
                loadedOriginal = original
                compareView.isHidden = false
                placeholder.isHidden = true
                compareView.setImages(original: original, compressed: nil)
                compareView.captions = (originalCaption(item, original), "")
            } catch {
                guard !Task.isCancelled, self.item?.id == item.id else { return }
                showStatus(error.localizedDescription, busy: false)
                return
            }
        }
        guard let original = loadedOriginal else { return }

        // 1. The cache is the truth: if the main window already made this preview
        //    the pane fills in immediately, with no encode and no spinner.
        var value = await PreviewCache.shared.value(for: key)

        // 2. Otherwise, if the coordinator is already working on this file, wait for
        //    it rather than starting a competing encode.
        if value == nil, item.isBusy {
            guard !Task.isCancelled, self.item?.id == item.id else { return }
            showStatus(waitingMessage(for: key.settings), busy: true)
            value = await waitForCachedPreview(key: key, item: item)
        }

        // 3. Nobody else is going to make it - make it here.
        if value == nil {
            guard !Task.isCancelled, self.item?.id == item.id else { return }
            showStatus(waitingMessage(for: key.settings), busy: true)
            value = await encodePreview(item: item, key: key)
        }

        guard !Task.isCancelled, self.item?.id == item.id else { return }

        guard let value else {
            let reason: String
            if case .failed(let message) = item.state { reason = message }
            else { reason = "Couldn't compress this file." }
            compareView.setCompressed(nil)
            showStatus(reason, busy: false)
            onDescriptionChanged?(nil)
            return
        }

        do {
            let compressed = try await ComparisonImageLoader.load(url: value.temporaryURL)
            guard !Task.isCancelled, self.item?.id == item.id else { return }
            compareView.setCompressed(compressed)
            compareView.captions = (originalCaption(item, original),
                                    compressedCaption(item, value, settings: key.settings))
            onDescriptionChanged?("Original vs \(encodingLabel(value, settings: key.settings))")
            shownKey = key
            hideStatus()
        } catch {
            showStatus(error.localizedDescription, busy: false)
        }
    }

    private func waitingMessage(for settings: EncodeSettings) -> String {
        settings.mode == .vlossless
            ? "Searching for the smallest visually lossless file…"
            : "Compressing preview…"
    }

    /// Polls the cache while the main window's coordinator works. Polling rather than
    /// subscribing keeps this view from having to reach into the coordinator at all.
    private func waitForCachedPreview(key: PreviewKey, item: FileItem) async -> PreviewValue? {
        for _ in 0..<150 { // ~30 s
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return nil }
            if let value = await PreviewCache.shared.value(for: key) { return value }
            if !item.isBusy { return await PreviewCache.shared.value(for: key) }
        }
        return nil
    }

    private func encodePreview(item: FileItem, key: PreviewKey) async -> PreviewValue? {
        do {
            let directory = await PreviewCache.shared.makeScratchDirectory()
            let result = try await SquishCLI.preview(url: item.url,
                                                     settings: key.settings,
                                                     into: directory)
            guard result.ok, let output = result.output, let bytesOut = result.bytesOut else {
                return nil
            }
            let value = PreviewValue(temporaryURL: URL(fileURLWithPath: output),
                                     bytesOut: bytesOut,
                                     quality: result.quality,
                                     score: result.score,
                                     belowTarget: result.belowTarget ?? false)
            await PreviewCache.shared.store(value, for: key)
            return value
        } catch {
            return nil
        }
    }

    // MARK: - Captions

    private func originalCaption(_ item: FileItem, _ image: LoadedImage) -> String {
        var parts = ["Original"]
        parts.append(Self.formatName(item.url.pathExtension))
        parts.append(Self.byteFormatter.string(fromByteCount: item.originalBytes))
        parts.append("\(Int(image.nativeSize.width))×\(Int(image.nativeSize.height))")
        return parts.joined(separator: " · ")
    }

    private func compressedCaption(_ item: FileItem,
                                   _ value: PreviewValue,
                                   settings: EncodeSettings) -> String {
        var parts = [encodingLabel(value, settings: settings)]
        parts.append(Self.byteFormatter.string(fromByteCount: value.bytesOut))
        if item.originalBytes > 0 {
            let saved = (Double(item.originalBytes - value.bytesOut) / Double(item.originalBytes)) * 100
            parts.append(String(format: "%.0f%% smaller", max(saved, 0)))
        }
        if value.belowTarget { parts.append("below target") }
        return parts.joined(separator: " · ")
    }

    private func encodingLabel(_ value: PreviewValue, settings: EncodeSettings) -> String {
        switch settings.mode {
        case .jpeg:
            return "JPEG q\(settings.quality)"
        case .webp:
            return "WebP q\(settings.quality)"
        case .vlossless:
            // vlossless keeps the input format, so name the format it actually kept.
            let format = Self.formatName(value.pathExtension)
            if let quality = value.quality {
                return "\(format) visually lossless q\(quality)"
            }
            return "\(format) visually lossless"
        }
    }

    private static func formatName(_ pathExtension: String) -> String {
        let upper = pathExtension.uppercased()
        return upper == "JPG" ? "JPEG" : upper
    }

    // MARK: - Status

    private func showStatus(_ text: String, busy: Bool) {
        statusLabel.stringValue = text
        statusOverlay.isHidden = false
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !busy
    }

    private func hideStatus() {
        spinner.stopAnimation(nil)
        statusOverlay.isHidden = true
    }

    private func showPlaceholder(_ message: String) {
        hideStatus()
        placeholder.stringValue = message
        placeholder.isHidden = false
        compareView.isHidden = true
        zoomBar.isHidden = true
    }

    // MARK: - Focus

    /// The comparison surface is what a click in this view should be talking to.
    override var acceptsFirstResponder: Bool { false }
    var comparisonSurface: NSView { compareView }
}

// MARK: - Rounded material masks

extension NSImage {
    /// A stretchable mask that gives an NSVisualEffectView genuinely rounded corners,
    /// including its vibrancy - a plain `cornerRadius` clips the layer but not the blur.
    static func roundedMask(cornerRadius: CGFloat) -> NSImage {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                       bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}
