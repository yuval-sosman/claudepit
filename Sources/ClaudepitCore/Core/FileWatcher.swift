import Foundation

public final class FileWatcher {
    private let paths: [URL]
    private let onChange: @Sendable () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private let queue = DispatchQueue(label: "claudepit.filewatcher")
    private var pending: DispatchWorkItem?

    public init(paths: [URL], onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    public func start() {
        for url in paths {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
            src.setEventHandler { [weak self] in self?.debounced() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
    }

    private func debounced() {
        pending?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    public func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    deinit {
        stop()
    }
}
