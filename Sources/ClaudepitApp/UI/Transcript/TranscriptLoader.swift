import Foundation
import ClaudepitCore

/// Owns one session file's live view: an incremental parse plus a FileWatcher, with the display
/// model rebuilt off the main thread. Rebuilds coalesce — a burst of appends while one is running
/// becomes one more — so a busy live session never queues work behind itself.
@MainActor
final class TranscriptLoader: ObservableObject {
    @Published private(set) var model: TranscriptModel?
    @Published private(set) var isLoading = false

    private let worker = Worker()
    private var watcher: FileWatcher?
    private var url: URL?
    private var running = false
    private var dirty = false

    func start(url: URL) {
        stop()
        self.url = url
        isLoading = model == nil
        refresh()
        watcher = FileWatcher(paths: [url]) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher?.start()
    }

    func stop() {
        watcher?.stop(); watcher = nil
    }

    /// Read whatever was appended and rebuild. Safe to call repeatedly.
    func refresh() {
        guard let url else { return }
        if running { dirty = true; return }
        running = true
        let worker = self.worker
        Task.detached(priority: .userInitiated) { [weak self] in
            let built = await worker.readAndBuild(url)
            await MainActor.run {
                guard let self else { return }
                if var built {
                    built.generation = (self.model?.generation ?? 0) + 1
                    self.model = built
                }
                // A file that can't be read still gets a (empty) page, never an endless spinner.
                else if self.model == nil { self.model = TranscriptModel(events: []) }
                self.isLoading = false
                self.running = false
                if self.dirty { self.dirty = false; self.refresh() }
            }
        }
    }

    /// The file tail, confined to one actor so reads never interleave.
    private actor Worker {
        private var tail: TranscriptFileTail?

        /// Parse the bytes appended since last time; nil when nothing changed.
        func readAndBuild(_ url: URL) -> TranscriptModel? {
            if tail?.url != url { tail = TranscriptFileTail(url: url) }
            guard let read = tail?.read() else { return nil }
            return TranscriptModel(events: read.events, metadata: read.metadata)
        }
    }
}
