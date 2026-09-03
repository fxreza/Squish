import Foundation

/// Turns a finished preview into a file on disk.
///
/// By the time this runs the compression has already happened - the bytes are
/// sitting in the preview cache's scratch area, and this only decides where they
/// go and puts them there. That is why pressing Compress is instant, and why what
/// the user saw in the Projected column is byte-for-byte what they get.
///
/// Placement mirrors `SquishCore.OutputPlanner` exactly, so the app and the CLI
/// never disagree about where a result belongs.
enum Exporter {

    struct Placement: Equatable, Sendable {
        var behavior: OutputBehavior
        var folder: URL?
        var suffix: String

        var isInPlace: Bool { behavior == .inplace }
    }

    enum ExportError: LocalizedError {
        case wouldOverwriteInput(URL)
        case noOutputFolder
        case io(String)

        var errorDescription: String? {
            switch self {
            case .wouldOverwriteInput(let url):
                return "\(url.lastPathComponent) would overwrite its own original. "
                     + "Change the suffix, or choose an output folder."
            case .noOutputFolder:
                return "No output folder is chosen. Pick one in Settings."
            case .io(let detail):
                return detail
            }
        }
    }

    /// Where `item` will land, given the preview it produced. Pure - safe to call
    /// for a dry run / tooltip.
    static func destination(for input: URL,
                            fileExtension: String,
                            placement: Placement) throws -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        let directory: URL
        switch placement.behavior {
        case .folder:
            guard let folder = placement.folder else { throw ExportError.noOutputFolder }
            directory = folder
        case .alongside, .inplace:
            directory = input.deletingLastPathComponent()
        }
        let name = placement.isInPlace ? stem : stem + placement.suffix
        let destination = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)

        if !placement.isInPlace, destination.standardizedFileURL == input.standardizedFileURL {
            throw ExportError.wouldOverwriteInput(input)
        }
        return destination
    }

    /// Copies the cached preview into place.
    ///
    /// Deliberately a copy, not a move: the cache entry stays valid, so exporting
    /// twice, or exporting and then flipping the mode back and forth, still costs
    /// nothing. Written atomically, exactly as the CLI writes it.
    ///
    /// The only circumstance in which an original is ever deleted is `--inplace`
    /// with a changed extension - the same rule `OutputPlanner` follows, because
    /// "overwrite the original" cannot mean "write JPEG bytes into a .tif".
    @discardableResult
    static func export(preview: PreviewValue,
                       from input: URL,
                       placement: Placement) throws -> URL {
        let destination = try destination(for: input,
                                          fileExtension: preview.pathExtension,
                                          placement: placement)

        let directory = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw ExportError.io("Couldn't create \(directory.path): \(error.localizedDescription)")
            }
        }

        let data: Data
        do {
            data = try Data(contentsOf: preview.temporaryURL)
        } catch {
            throw ExportError.io("The cached preview vanished. Try again.")
        }

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ExportError.io("Couldn't write \(destination.lastPathComponent): \(error.localizedDescription)")
        }

        if placement.isInPlace, destination.standardizedFileURL != input.standardizedFileURL {
            try? FileManager.default.removeItem(at: input)
        }

        return destination
    }
}
