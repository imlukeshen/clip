import Darwin
import Foundation

public final class LibraryRootWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?

    public init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue(label: "app.reel.library-watch", qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { [descriptor] in close(descriptor) }
        self.source = source
        source.resume()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit { stop() }
}
