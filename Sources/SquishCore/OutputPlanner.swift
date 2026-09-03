import Foundation

/// Decides where a result goes and puts it there without ever clobbering an input by accident.
public enum OutputPlanner {

    /// `--out DIR` wins over the input's own directory; `--inplace` drops the suffix.
    ///
    /// Note that `jpeg`/`webp` change the extension, so `--inplace` on `photo.tif` in `jpeg` mode
    /// produces `photo.jpg` and removes `photo.tif` - "overwrite the original" cannot mean
    /// "write JPEG bytes into a .tif".
    public static func destination(for input: URL,
                                   fileExtension: String,
                                   options: SquishOptions) throws -> URL {
        let stem = input.deletingPathExtension().lastPathComponent
        let directory = options.outDir ?? input.deletingLastPathComponent()
        let name = options.inplace ? stem : stem + options.suffix
        let url = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)

        if !options.inplace && url.standardizedFileURL == input.standardizedFileURL {
            throw SquishError.wouldOverwriteInput(url: input)
        }
        return url
    }

    public static func write(_ data: Data,
                             to destination: URL,
                             replacing input: URL,
                             options: SquishOptions) throws {
        let directory = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw SquishError.io("could not create \(directory.path): \(error.localizedDescription)")
            }
        }
        // Belt and braces: even with --inplace off, refuse to land on the input.
        if !options.inplace && destination.standardizedFileURL == input.standardizedFileURL {
            throw SquishError.wouldOverwriteInput(url: input)
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw SquishError.io("could not write \(destination.path): \(error.localizedDescription)")
        }
        if options.inplace, destination.standardizedFileURL != input.standardizedFileURL {
            try? FileManager.default.removeItem(at: input)
        }
    }
}
