import AppKit

/// The standalone before/after window - the escape hatch for serious pixel-peeping:
/// full screen, a second monitor, 400% zoom, several files side by side.
///
/// It is a thin host around `ComparisonView`, the same component the main window
/// embeds as a pane, so the two surfaces cannot drift apart.
///
/// One window per file: asking to compare a file that already has a window brings
/// that window forward instead of opening a second one.
@MainActor
final class CompareWindowController: NSWindowController, NSWindowDelegate {

    // MARK: - Registry

    private static var open: [UUID: CompareWindowController] = [:]

    @discardableResult
    static func present(item: FileItem, settings: EncodeSettings) -> CompareWindowController {
        if let existing = open[item.id] {
            existing.update(settings: settings)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = CompareWindowController(item: item, settings: settings)
        open[item.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// Called by the main window whenever its previews change - which covers a mode
    /// switch, a quality change, and a preview finishing. Every open comparison
    /// re-resolves itself against the new settings.
    static func mainWindowDidUpdate(settings: EncodeSettings) {
        for controller in open.values {
            controller.update(settings: settings)
        }
    }

    // MARK: - State

    private let item: FileItem
    private var settings: EncodeSettings
    private let comparison = ComparisonView(frame: .zero)

    private init(item: FileItem, settings: EncodeSettings) {
        self.item = item
        self.settings = settings.normalized

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = item.url.lastPathComponent
        window.minSize = NSSize(width: 480, height: 380)
        window.center()
        window.setFrameAutosaveName("SquishCompareWindow")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        if let contentView = window.contentView {
            comparison.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(comparison)
            NSLayoutConstraint.activate([
                comparison.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                comparison.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                comparison.topAnchor.constraint(equalTo: contentView.topAnchor),
                comparison.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
        comparison.onDescriptionChanged = { [weak self] description in
            self?.window?.subtitle = description ?? ""
        }
        comparison.show(item: item, settings: self.settings)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func update(settings newSettings: EncodeSettings) {
        settings = newSettings.normalized
        comparison.show(item: item, settings: settings)
    }

    // MARK: - Window lifecycle

    func windowWillClose(_ notification: Notification) {
        comparison.clear(message: "")
        CompareWindowController.open.removeValue(forKey: item.id)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(comparison.comparisonSurface)
    }
}
