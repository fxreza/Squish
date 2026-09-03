import AppKit

/// Keeps every row's projected size in step with the current mode and quality.
///
/// Three things make this cheap enough to run on every slider nudge:
///
///  1. **Cache first.** Every item is looked up in `PreviewCache` before any process
///     is spawned, so revisiting a setting is instant and never flickers through a
///     "calculating" state.
///  2. **Debounce.** Slider-driven refreshes wait ~250 ms after the user stops moving,
///     so a drag across the whole track spawns one pass, not eighty.
///  3. **Bounded concurrency + cancellation.** Misses run in a task group capped a
///     little below the core count, and a superseded pass terminates its subprocesses
///     rather than letting them finish work nobody will look at.
@MainActor
final class PreviewCoordinator {

    struct Failure: Error, Sendable {
        var message: String
    }

    private let cache = PreviewCache.shared
    private var refreshTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// Leaves headroom so the UI, and the encoders' own internal threads, still get CPU.
    private let concurrencyLimit = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))

    static let debounceInterval: Duration = .milliseconds(250)

    /// Progress of the pass currently running, for the window's progress bar.
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    var isRunning: Bool { refreshTask != nil }

    /// Fired when one or more rows changed and the table/footer should redraw.
    var onChange: (() -> Void)?

    // MARK: - Scheduling

    /// Debounced entry point - used by the slider.
    func scheduleRefresh(items: [FileItem], settings: EncodeSettings) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: PreviewCoordinator.debounceInterval)
            guard !Task.isCancelled, let self else { return }
            self.refresh(items: items, settings: settings)
        }
    }

    /// Immediate entry point - used by drops, mode changes and the Compress button.
    func refresh(items: [FileItem], settings: EncodeSettings) {
        debounceTask?.cancel()
        debounceTask = nil
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.run(items: items, settings: settings)
        }
    }

    /// Awaitable version: resolves once every row has a preview (or a failure).
    /// The Compress button uses this so it can guarantee it is copying finished work.
    func refreshAndWait(items: [FileItem], settings: EncodeSettings) async {
        debounceTask?.cancel()
        debounceTask = nil
        refreshTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(items: items, settings: settings)
        }
        refreshTask = task
        await task.value
    }

    func cancel() {
        debounceTask?.cancel()
        debounceTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        completedCount = 0
        totalCount = 0
    }

    // MARK: - The pass

    private func run(items: [FileItem], settings: EncodeSettings) async {
        let normalized = settings.normalized

        // Phase 1 - resolve everything the cache already knows, synchronously from the
        // UI's point of view. Rows that hit never show a spinner.
        var misses: [FileItem] = []
        for item in items {
            item.refreshFingerprint()
            let key = item.key(for: normalized)
            if let cached = await cache.value(for: key) {
                item.state = .ready(cached)
            } else {
                item.state = .calculating
                misses.append(item)
            }
        }

        completedCount = 0
        totalCount = misses.count
        onChange?()

        guard !misses.isEmpty else {
            refreshTask = nil
            onChange?()
            return
        }

        if Task.isCancelled {
            markCancelled(misses)
            return
        }

        // Phase 2 - encode the misses, at most `concurrencyLimit` at a time.
        let byID = Dictionary(uniqueKeysWithValues: misses.map { ($0.id, $0) })
        var queue = misses.map { (id: $0.id, url: $0.url, key: $0.key(for: normalized)) }[...]

        await withTaskGroup(of: (UUID, Result<PreviewValue, Failure>).self) { group in
            func addNext() {
                guard !Task.isCancelled, let job = queue.popFirst() else { return }
                let cache = self.cache
                group.addTask {
                    do {
                        let directory = await cache.makeScratchDirectory()
                        let result = try await SquishCLI.preview(url: job.url,
                                                                 settings: job.key.settings,
                                                                 into: directory)
                        guard result.ok, let output = result.output, let bytesOut = result.bytesOut else {
                            let message = result.error ?? "Compression failed"
                            return (job.id, .failure(Failure(message: message)))
                        }
                        let value = PreviewValue(temporaryURL: URL(fileURLWithPath: output),
                                                 bytesOut: bytesOut,
                                                 quality: result.quality,
                                                 score: result.score,
                                                 belowTarget: result.belowTarget ?? false)
                        await cache.store(value, for: job.key)
                        return (job.id, .success(value))
                    } catch is CancellationError {
                        return (job.id, .failure(Failure(message: "Cancelled")))
                    } catch {
                        return (job.id, .failure(Failure(message: error.localizedDescription)))
                    }
                }
            }

            for _ in 0..<concurrencyLimit { addNext() }

            while let (id, outcome) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if let item = byID[id] {
                    switch outcome {
                    case .success(let value):
                        item.state = .ready(value)
                    case .failure(let failure):
                        item.state = .failed(Self.shortened(failure.message))
                    }
                }
                completedCount += 1
                onChange?()
                addNext()
            }
        }

        if Task.isCancelled {
            markCancelled(misses)
            return
        }

        refreshTask = nil
        completedCount = 0
        totalCount = 0
        onChange?()
    }

    /// A superseded pass leaves its unfinished rows back at `.pending`; the pass that
    /// replaced it is already recomputing them.
    private func markCancelled(_ items: [FileItem]) {
        for item in items where item.isBusy {
            item.state = .pending
        }
        completedCount = 0
        totalCount = 0
    }

    /// CLI errors are whole sentences; the Status column has about 30 characters.
    private static func shortened(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(separator: ":").last.map(String.init) else { return trimmed }
        let candidate = first.trimmingCharacters(in: .whitespaces)
        return candidate.isEmpty ? trimmed : candidate
    }
}
