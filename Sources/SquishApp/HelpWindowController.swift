import AppKit

/// A short, always-available quick reference.
///
/// Deliberately built in, not a link to the repo README: the README isn't inside the
/// .app bundle, and a Help menu item that opens nothing is worse than no Help menu.
/// Like Klip's changelog window this is a plain resizable `NSWindow` rather than a
/// panel - it is something you sit and read, not something that should vanish the
/// moment you click elsewhere.
final class HelpWindowController: NSWindowController {

    static let shared = HelpWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Squish Help"
        window.minSize = NSSize(width: 380, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        build()
    }

    private func build() {
        guard let contentView = window?.contentView else { return }

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.textStorage?.setAttributedString(Self.body())

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        textView.autoresizingMask = [.width]
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Content

    private static func body() -> NSAttributedString {
        let result = NSMutableAttributedString()

        func heading(_ text: String) {
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]))
        }

        func paragraph(_ text: String) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 10
            style.lineSpacing = 2
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style
            ]))
        }

        func spacer() {
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 5)
            ]))
        }

        heading("How Squish works")
        paragraph("""
        Dropping images only adds them to the list. Squish immediately compresses \
        each one into a scratch area so the Projected column shows the exact size \
        you would get - never an estimate - and nothing reaches your disk until you \
        press Compress (⌘↩).
        """)
        spacer()

        heading("The three modes")
        paragraph("""
        JPEG — mozjpeg at the quality you pick. Progressive and optimised. Always \
        writes .jpg, from any of the ~62 formats ImageIO reads.

        WebP — cwebp at the quality you pick. Always writes .webp.

        Visually Lossless — no fixed quality. Squish searches for the smallest file \
        that a perceptual metric still scores at or above your target, so the slider \
        becomes a Visual target instead. 90 is the usual "can't tell them apart" \
        mark. The input format is kept: JPEG in, JPEG out. It is slower, because it \
        encodes the same image several times.
        """)
        spacer()

        heading("Quality")
        paragraph("""
        The slider in the main window is the only quality control in the app, and it \
        starts at 75% every launch by design. Move it and every row recalculates. \
        Settings holds only where results are written and what they are named.
        """)
        spacer()

        heading("Keyboard")
        paragraph("""
        ⌘O   Add files
        ⇧⌘O  Add a folder (including subfolders)
        ⌘↩   Compress everything in the list
        ⌘1 ⌘2 ⌘3   Switch mode
        ⌘A   Select every row
        ⌫ or ⌘⌫   Remove the selected rows from the list
        ⇧⌘R  Reveal the selection in Finder
        ⌘,   Settings
        """)
        spacer()

        heading("Your originals")
        paragraph("""
        Removing a row never deletes anything - it only takes the entry out of the \
        list. The only command that touches an original is "Move Original File to \
        Trash…" in the right-click menu, and it asks first. Output normally lands \
        beside the original with a -squish suffix; Settings can send it to a folder \
        instead, or overwrite in place.
        """)

        return result
    }
}
