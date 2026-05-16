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
        let path = name.hasPrefix("/")
            ? name
            : self.viewsDirectory + name
        #if os(Windows)
        // Windows: route through Vapor's WindowsFile shim (built on NIOPosix).
        return eventLoop.makeFutureWithTask {
            let buffer = try await WindowsFile.readToEnd(at: path, maxBytes: 32 * 1024 * 1024)
            return View(data: buffer)
        }
        #else
        return eventLoop.makeFutureWithTask {
            try await FileSystem.shared.withFileHandle(forReadingAt: .init(path)) { handle in
                let buffer = try await handle.readToEnd(maximumSizeAllowed: .megabytes(32))
                return View(data: buffer)
            }
        }
        #endif
    }
}
