// SPDX-License-Identifier: MIT
//
// Windows-only WebSocket support for Vapor.
//
// Background: Vapor's normal WebSocket path uses `WebSocketKit`, which transitively imports
// the NIOSSL Swift module. NIOSSL's Swift module is unbuildable on Windows
// (`#error("unsupported os")` in 7+ files of apple/swift-nio-ssl HEAD 2026-05). This file
// provides a Windows-only replacement built on top of `WSCore` (swift-websocket 1.5.0),
// which does NOT pull NIOSSL on the 1.5.0 tag. Vapor's Package.swift pins swift-websocket
// to `exact: "1.5.0"` and only links `WSCore` on Windows.
//
// The Windows `WebSocket` exposes a subset of `WebSocketKit.WebSocket`'s API: enough to
// register text/binary callbacks, send text/binary frames, observe close, and close the
// session. Unsupported features (custom ping/pong handlers, `onText` async variant
// observers, `WebSocketProtocolErrorHandler`, etc.) raise compile-time errors so callers
// know what's missing. The rest of Vapor's WebSocket source files
// (Request+WebSocket.swift, RoutesBuilder+WebSocket.swift, WebSocket+Concurrency.swift)
// reference the unqualified `WebSocket` and `WebSocketUpgrader` symbols — they resolve to
// these definitions on Windows and to WebSocketKit on every other platform.
//
// See bucket/HANDOFF-vapor-investigation-2026-05-14.md and
// bucket/WINDOWS_PATCHES-vapor-section-draft.md for the design rationale.

#if os(Windows)

import Logging
import NIOCore
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOPosix
import NIOWebSocket
@_spi(WSInternal) import WSCore

/// WebSocket maximum frame size, in bytes.
///
/// Mirrors the type defined for non-Windows platforms in
/// `Sources/Vapor/Routing/RoutesBuilder+WebSocket.swift`.
public struct WebSocketMaxFrameSize: Sendable, ExpressibleByIntegerLiteral {
    let value: Int

    public init(integerLiteral value: Int) {
        self.value = value
    }

    public static var `default`: Self {
        self.init(integerLiteral: 1 << 14)
    }
}

// MARK: - WebSocket facade

/// Minimal Windows-only WebSocket facade.
///
/// Exposes a subset of the API offered by `WebSocketKit.WebSocket`. The handler is driven
/// from a Task that runs WSCore's `WebSocketHandler.handle` on the upgraded channel; that
/// Task feeds frames into this facade by calling `_dispatchInbound(_:)`.
public final class WebSocket: Sendable {
    /// Event loop the underlying channel is bound to.
    public let eventLoop: any EventLoop

    /// Future that fires when the WebSocket session terminates.
    public var onClose: EventLoopFuture<Void> { self._closePromise.futureResult }

    /// Logger used by the runtime for diagnostic messages.
    public let logger: Logger

    fileprivate typealias TextHandler = @Sendable (WebSocket, String) -> Void
    fileprivate typealias BinaryHandler = @Sendable (WebSocket, ByteBuffer) -> Void

    private struct State {
        var onText: TextHandler?
        var onBinary: BinaryHandler?
        var closed: Bool = false
    }

    private let _state: NIOLockedValueBox<State>
    private let _outbound: WebSocketOutboundWriter
    private let _closePromise: EventLoopPromise<Void>

    init(
        eventLoop: any EventLoop,
        logger: Logger,
        outbound: WebSocketOutboundWriter,
        closePromise: EventLoopPromise<Void>
    ) {
        self.eventLoop = eventLoop
        self.logger = logger
        self._outbound = outbound
        self._closePromise = closePromise
        self._state = .init(State())
    }

    // MARK: Inbound callbacks

    /// Register a callback invoked when a complete text message arrives.
    @preconcurrency
    public func onText(_ callback: @escaping @Sendable (WebSocket, String) -> Void) {
        self._state.withLockedValue { $0.onText = callback }
    }

    /// Register a callback invoked when a complete binary message arrives.
    @preconcurrency
    public func onBinary(_ callback: @escaping @Sendable (WebSocket, ByteBuffer) -> Void) {
        self._state.withLockedValue { $0.onBinary = callback }
    }

    // MARK: Outbound writes

    /// Send a text frame. Fire-and-forget; the optional promise reports completion.
    public func send(_ text: String, promise: EventLoopPromise<Void>? = nil) {
        let outbound = self._outbound
        Task {
            do {
                try await outbound.write(.text(text))
                promise?.succeed(())
            } catch {
                promise?.fail(error)
            }
        }
    }

    /// Send a text frame; async variant.
    public func send(_ text: String) async throws {
        try await self._outbound.write(.text(text))
    }

    /// Send a binary frame; async variant.
    public func send(_ binary: ByteBuffer) async throws {
        try await self._outbound.write(.binary(binary))
    }

    /// Send a binary frame from any UInt8 collection.
    public func send<Bytes: Collection>(
        _ binary: Bytes,
        promise: EventLoopPromise<Void>? = nil
    ) where Bytes.Element == UInt8 {
        var buffer = ByteBufferAllocator().buffer(capacity: binary.count)
        buffer.writeBytes(binary)
        let outbound = self._outbound
        Task {
            do {
                try await outbound.write(.binary(buffer))
                promise?.succeed(())
            } catch {
                promise?.fail(error)
            }
        }
    }

    // MARK: Close

    /// Close the WebSocket session. Async variant.
    public func close(code: WebSocketErrorCode = .goingAway) async throws {
        let alreadyClosed: Bool = self._state.withLockedValue { state in
            if state.closed { return true }
            state.closed = true
            return false
        }
        guard !alreadyClosed else { return }
        try await self._outbound.close(code, reason: nil)
    }

    /// Close the WebSocket session. EventLoopFuture variant.
    @discardableResult
    public func close(code: WebSocketErrorCode = .goingAway) -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        Task { [weak self] in
            do {
                try await self?.close(code: code)
                promise.succeed(())
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    // MARK: Internal dispatch (called by the WSCore-driven Task)

    func _dispatch(message: WebSocketMessage) {
        switch message {
        case .text(let string):
            let handler = self._state.withLockedValue { $0.onText }
            handler?(self, string)
        case .binary(let buffer):
            let handler = self._state.withLockedValue { $0.onBinary }
            handler?(self, buffer)
        }
    }

    func _completeClose() {
        self._state.withLockedValue { $0.closed = true }
        self._closePromise.succeed(())
    }

    func _failClose(_ error: any Error) {
        self._state.withLockedValue { $0.closed = true }
        self._closePromise.fail(error)
    }
}

// MARK: - WSCore context

private struct VaporWebSocketContext: WebSocketContext {
    let logger: Logger
}

// MARK: - WebSocketUpgrader

/// Handles upgrading an HTTP connection to a WebSocket on Windows.
///
/// Mirrors the non-Windows `WebSocketUpgrader` in
/// `Sources/Vapor/HTTP/Server/HTTPServerUpgradeHandler.swift`. Internally it uses
/// `NIOWebSocketServerUpgrader` (from apple/swift-nio's NIOWebSocket module, which builds
/// fine on Windows via the substrate) and hands off to WSCore's `WebSocketHandler.handle`
/// after the protocol upgrade completes.
public struct WebSocketUpgrader: Upgrader, Sendable {
    var maxFrameSize: WebSocketMaxFrameSize
    var shouldUpgrade: (@Sendable () -> EventLoopFuture<HTTPHeaders?>)
    var onUpgrade: @Sendable (WebSocket) -> Void

    @preconcurrency public init(
        maxFrameSize: WebSocketMaxFrameSize,
        shouldUpgrade: @escaping @Sendable () -> EventLoopFuture<HTTPHeaders?>,
        onUpgrade: @escaping @Sendable (WebSocket) -> Void
    ) {
        self.maxFrameSize = maxFrameSize
        self.shouldUpgrade = shouldUpgrade
        self.onUpgrade = onUpgrade
    }

    public func applyUpgrade(req: Request, res: Response) -> HTTPServerProtocolUpgrader {
        let logger = req.logger
        let maxFrameSize = self.maxFrameSize.value
        let shouldUpgrade = self.shouldUpgrade
        let onUpgrade = self.onUpgrade

        return NIOWebSocketServerUpgrader(
            maxFrameSize: maxFrameSize,
            automaticErrorHandling: false,
            shouldUpgrade: { _, _ in shouldUpgrade() },
            upgradePipelineHandler: { channel, _ in
                Self.runWebSocketSession(
                    channel: channel,
                    logger: logger,
                    maxFrameSize: maxFrameSize,
                    onUpgrade: onUpgrade
                )
            }
        )
    }

    /// Wraps the upgraded channel with `NIOAsyncChannel<WebSocketFrame, WebSocketFrame>` and
    /// spawns a Task running `WSCore.WebSocketHandler.handle`. The user's `onUpgrade`
    /// closure runs inside the WSCore handler so it can register callbacks before frames
    /// start arriving.
    private static func runWebSocketSession(
        channel: any Channel,
        logger: Logger,
        maxFrameSize: Int,
        onUpgrade: @escaping @Sendable (WebSocket) -> Void
    ) -> EventLoopFuture<Void> {
        let eventLoop = channel.eventLoop
        let closePromise = eventLoop.makePromise(of: Void.self)
        do {
            let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                wrappingChannelSynchronously: channel
            )
            Task { [logger] in
                do {
                    let context = VaporWebSocketContext(logger: logger)
                    let configuration = WebSocketHandler.Configuration(
                        extensions: [],
                        autoPing: .disabled,
                        validateUTF8: true
                    )
                    _ = try await WebSocketHandler.handle(
                        type: .server,
                        configuration: configuration,
                        asyncChannel: asyncChannel,
                        context: context
                    ) { inbound, outbound, ctx in
                        let ws = WebSocket(
                            eventLoop: eventLoop,
                            logger: ctx.logger,
                            outbound: outbound,
                            closePromise: closePromise
                        )
                        // Hand the facade to the user so they can register callbacks
                        // before we start pulling frames.
                        onUpgrade(ws)

                        do {
                            for try await message in inbound.messages(maxSize: maxFrameSize * 64) {
                                ws._dispatch(message: message)
                            }
                            ws._completeClose()
                        } catch {
                            ws._failClose(error)
                            throw error
                        }
                    }
                    // Belt-and-braces: if `handle` returned without our inner loop firing
                    // the close (e.g. an early protocol abort), make sure onClose still
                    // resolves so consumers waiting on it don't hang.
                    closePromise.succeed(())
                } catch {
                    logger.debug("Vapor WebSocket session terminated with error: \(error)")
                    closePromise.fail(error)
                }
            }
            return eventLoop.makeSucceededFuture(())
        } catch {
            logger.warning("Vapor WebSocket: failed to wrap channel: \(error)")
            closePromise.fail(error)
            return eventLoop.makeFailedFuture(error)
        }
    }
}

#endif
