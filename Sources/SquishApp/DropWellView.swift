import AppKit
import UniformTypeIdentifiers

/// The whole list area is the drop target, not a separate well: files land wherever
/// you let go, and the container draws an accent ring while a drag is over it.
/// When the list is empty it shows the empty state instead of an empty table.
final class DropContainerView: NSView {

    var onDrop: (([URL]) -> Void)?

    private var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHighlighted else { return }
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        path.fill()
    }

    private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options
        ) as? [URL] else {
            return []
        }
        return urls
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        isHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        isHighlighted = false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        isHighlighted = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isHighlighted = false
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// Shown in place of the table when nothing has been added yet. Explains the two
/// ways in and nothing else.
final class EmptyStateView: NSView {

    var onChooseFiles: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                               accessibilityDescription: nil)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
        symbol.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "Drop images here")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "Explore modes and quality first. Nothing is written until you press Compress.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.alignment = .center

        let button = NSButton(title: "Choose Files…", target: self, action: #selector(chooseFiles))
        button.bezelStyle = .rounded
        button.controlSize = .regular

        let stack = NSStackView(views: [symbol, title, subtitle, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(12, after: symbol)
        stack.setCustomSpacing(14, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    @objc private func chooseFiles() {
        onChooseFiles?()
    }
}

/// Expands whatever was dropped or picked into a flat list of image files.
enum FileGatherer {

    /// Directories are walked recursively, hidden files and package contents skipped.
    /// Anything ImageIO wouldn't recognise is dropped here rather than handed to the
    /// CLI only to come back as a per-row failure.
    static func imageFiles(from urls: [URL]) -> [URL] {
        var results: [URL] = []
        var seen = Set<String>()

        func consider(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard isImage(standardized), seen.insert(standardized.path).inserted else { return }
            results.append(standardized)
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let child = enumerator?.nextObject() as? URL {
                    consider(child)
                }
            } else {
                consider(url)
            }
        }
        return results
    }

    private static func isImage(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return type.conforms(to: .image)
    }
}
