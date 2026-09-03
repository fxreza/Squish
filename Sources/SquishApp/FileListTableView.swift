import AppKit

@MainActor
protocol FileListTableViewDelegate: AnyObject {
    /// Delete / Backspace / Cmd+Delete: take the selection out of the list.
    /// Never touches the file on disk.
    func fileListRemoveSelection()
}

/// NSTableView subclass that adds the two Finder behaviours AppKit doesn't give
/// for free: Delete/Backspace (with or without Cmd) removes the selection, and
/// a right-click on a row inside the selection acts on the whole selection rather
/// than collapsing to the clicked row.
final class FileListTableView: NSTableView {

    weak var actionDelegate: (any FileListTableViewDelegate)?

    override func keyDown(with event: NSEvent) {
        // 51 = Delete (Backspace), 117 = Forward Delete. Cmd+Delete lands here too;
        // in Finder that means "move to trash", but the brief is explicit that in
        // Squish both plain Delete and Cmd+Delete mean "remove from this list".
        if event.keyCode == 51 || event.keyCode == 117 {
            if selectedRowIndexes.isEmpty {
                NSSound.beep()
            } else {
                actionDelegate?.fileListRemoveSelection()
            }
            return
        }
        super.keyDown(with: event)
    }

    /// Right-clicking a row that is *not* part of the current selection selects it
    /// first (Finder's behaviour); right-clicking inside the selection leaves the
    /// selection alone so the menu can act on all of it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if row < 0 {
            deselectAll(nil)
        }
        return super.menu(for: event)
    }
}

/// The Status column: an optional small spinner plus a label, so an in-flight row
/// reads as working rather than as an empty cell.
final class StatusCellView: NSTableCellView {

    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(spinner)
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 12),
            spinner.heightAnchor.constraint(equalToConstant: 12),

            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, busy: Bool, tint: NSColor) {
        label.stringValue = text
        label.textColor = tint
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        // Reclaim the spinner's gutter when it's hidden so text lines up with the
        // header, but keep the constraint constant stable to avoid a reflow.
        spinner.isHidden = !busy
    }
}
