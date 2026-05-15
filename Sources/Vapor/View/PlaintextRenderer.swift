import NIOCore
import NIOPosix
import Logging
#if !os(Windows)
import _NIOFileSystem
#endif

public struct PlaintextRenderer: ViewRenderer, Sendable {
    public let eventLoopGroup: EventLoopGroup
    private let fileio: NonBlockingFileIO
    private let viewsDirectory: String
    private let logger: Logger

    public init(
        fileio: NonBlockingFileIO,
        viewsDirectory: String,
        logger: Logger,
        eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.fileio = fileio
        self.viewsDirectory = viewsDirectory.finished(with: "/")
        self.logger = logger
        self.eventLoopGroup = eventLoopGroup
    }
    
    public func `for`(_ request: Request) -> ViewRenderer {
        PlaintextRenderer(
            fileio: request.application.fileio,
            viewsDirectory: self.viewsDirectory,
            logger: request.logger,
            eventLoopGroup: request.eventLoop
        )
    }

    public func render<E>(_ name: String, _ context: E) -> EventLoopFuture<View>
        where E: Encodable
    {
        self.logger.trace("Rendering plaintext view \(name) with \(context)")
        let eventLoop = self.eventLoopGroup.next()
        #if os(Windows)
        // _NIOFileSystem is unavailable on Windows. Users wanting templates on Windows must
        // install a custom ViewRenderer via `app.views.use(...)`.
        self.logger.error("PlaintextRenderer is unavailable on Windows (no _NIOFileSystem). Configure app.views.use(...) with a Windows-compatible renderer.")
        _ = name
        return eventLoop.makeFailedFuture(Abort(.notImplemented, reason: "PlaintextRenderer is unavailable on Windows (no _NIOFileSystem)"))
        #else
        let path = name.hasPrefix("/")
            ? name
            : self.viewsDirectory + name
        return eventLoop.makeFutureWithTask {
            try await FileSystem.shared.withFileHandle(forReadingAt: .init(path)) { handle in
                let buffer = try await handle.readToEnd(maximumSizeAllowed: .megabytes(32))
                return View(data: buffer)
            }
        }
        #endif
    }
}
