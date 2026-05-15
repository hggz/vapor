// WebSocket routes work on every platform: on non-Windows the underlying `WebSocket` and
// `WebSocketUpgrader` come from WebSocketKit; on Windows they come from
// `Sources/Vapor/HTTP/Server/WebSocketWindows.swift` (backed by WSCore). The only platform
// gate here is the `import WebSocketKit` line — `WebSocketMaxFrameSize` is defined here
// for non-Windows callers and in WebSocketWindows.swift for Windows callers.
import RoutingKit
#if !os(Windows)
import WebSocketKit
#endif
import NIOCore
import NIOHTTP1

#if !os(Windows)
public struct WebSocketMaxFrameSize: Sendable, ExpressibleByIntegerLiteral {
    let value: Int

    public init(integerLiteral value: Int) {
        self.value = value
    }

    public static var `default`: Self {
        self.init(integerLiteral: 1 << 14)
    }
}
#endif

// Deprecated
extension RoutesBuilder {
    /// Adds a route for opening a web socket connection
    /// - parameters:
    ///   - path: Path components separated by commas.
    ///   - maxFrameSize: The maximum allowed frame size. See `NIOWebSocketServerUpgrader`.
    ///   - shouldUpgrade: Closure to apply before upgrade to web socket happens.
    ///       Returns additional `HTTPHeaders` for response, `nil` to deny upgrading.
    ///       See `NIOWebSocketServerUpgrader`.
    ///   - onUpgrade: Closure to apply after web socket is upgraded successfully.
    /// - returns: `Route` instance for newly created web socket endpoint
    @preconcurrency
    @discardableResult
    public func webSocket(
        _ path: PathComponent...,
        maxFrameSize: WebSocketMaxFrameSize = .`default`,
        shouldUpgrade: @escaping (@Sendable (Request) -> EventLoopFuture<HTTPHeaders?>) = {
            $0.eventLoop.makeSucceededFuture([:])
        },
        onUpgrade: @Sendable @escaping (Request, WebSocket) -> ()
    ) -> Route {
        return self.webSocket(path, maxFrameSize: maxFrameSize, shouldUpgrade: shouldUpgrade, onUpgrade: onUpgrade)
    }

    /// Adds a route for opening a web socket connection
    /// - parameters:
    ///   - path: Array of path components.
    ///   - maxFrameSize: The maximum allowed frame size. See `NIOWebSocketServerUpgrader`.
    ///   - shouldUpgrade: Closure to apply before upgrade to web socket happens.
    ///       Returns additional `HTTPHeaders` for response, `nil` to deny upgrading.
    ///       See `NIOWebSocketServerUpgrader`.
    ///   - onUpgrade: Closure to apply after web socket is upgraded successfully.
    /// - returns: `Route` instance for newly created web socket endpoint
    @preconcurrency
    @discardableResult
    public func webSocket(
        _ path: [PathComponent],
        maxFrameSize: WebSocketMaxFrameSize = .`default`,
        shouldUpgrade: @escaping (@Sendable (Request) -> EventLoopFuture<HTTPHeaders?>) = {
            $0.eventLoop.makeSucceededFuture([:])
        },
        onUpgrade: @Sendable @escaping (Request, WebSocket) -> ()
    ) -> Route {
        return self.on(.GET, path) { request -> Response in
            let res = Response(status: .switchingProtocols)
            res.upgrader = WebSocketUpgrader(maxFrameSize: maxFrameSize, shouldUpgrade: {
                shouldUpgrade(request)                
            }, onUpgrade: { ws in
                onUpgrade(request, ws)
            })
            return res
        }
    }
}
