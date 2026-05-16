// SPDX-License-Identifier: MIT
//
// Windows-only minimal HTTP/1.1 client used by Vapor in place of AsyncHTTPClient.
//
// Background: Vapor's normal `Request.client` / `app.client` path is backed by
// `AsyncHTTPClient`, which transitively imports the `NIOSSL` Swift module \u2014
// unbuildable on Windows because the upstream `apple/swift-nio-ssl` Swift module
// has `#error("unsupported os")` in 7+ files. The whole `HTTP/Client/*` directory
// is therefore wholesale `#if !os(Windows)` gated.
//
// `WindowsHTTPClient` provides a small replacement that conforms to Vapor's `Client`
// protocol using NIOPosix (`ClientBootstrap`) + NIOHTTP1 (`HTTPRequestEncoder`,
// `HTTPResponseDecoder`) directly. It supports **plaintext `http://` only** \u2014 no TLS,
// no connection pooling, no HTTP/2, no redirects. Each `send(_:)` opens a fresh TCP
// connection, sends one request/response pair, and closes the connection.
//
// This is intentionally minimal: enough to call out to internal services / metadata
// endpoints / health checks on Windows where TLS isn't required. Production
// deployments needing HTTPS or connection reuse should wait for upstream NIOSSL
// Swift Windows support, then switch to the standard AHC-backed client.
//
// Also provides `Application.HTTP.Client` and `Application.Clients.Provider.http`
// extensions so that `app.clients.use(.http)` works the same way as on POSIX
// platforms.
//
// See bucket/HANDOFF-vapor-investigation-2026-05-14.md and
// bucket/WINDOWS_PATCHES-vapor-section-draft.md for the design rationale.

#if os(Windows)

import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

// MARK: - WindowsHTTPClient

/// Minimal Windows-only `Client` implementation backed by NIOPosix + NIOHTTP1.
///
/// Plaintext HTTP/1.1 only. One TCP connection per request. Not thread-pooled.
public struct WindowsHTTPClient: Client {
    public let eventLoop: any EventLoop
    public var byteBufferAllocator: ByteBufferAllocator
    private let logger: Logger?

    public init(
        eventLoop: any EventLoop,
        byteBufferAllocator: ByteBufferAllocator = ByteBufferAllocator(),
        logger: Logger? = nil
    ) {
        self.eventLoop = eventLoop
        self.byteBufferAllocator = byteBufferAllocator
        self.logger = logger
    }

    public func delegating(to eventLoop: any EventLoop) -> any Client {
        WindowsHTTPClient(eventLoop: eventLoop, byteBufferAllocator: self.byteBufferAllocator, logger: self.logger)
    }

    public func logging(to logger: Logger) -> any Client {
        WindowsHTTPClient(eventLoop: self.eventLoop, byteBufferAllocator: self.byteBufferAllocator, logger: logger)
    }

    public func allocating(to byteBufferAllocator: ByteBufferAllocator) -> any Client {
        WindowsHTTPClient(eventLoop: self.eventLoop, byteBufferAllocator: byteBufferAllocator, logger: self.logger)
    }

    public func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let eventLoop = self.eventLoop
        let allocator = self.byteBufferAllocator
        let logger = self.logger

        // Parse the URI. We need scheme, host, port, and the path+query as written.
        guard let scheme = request.url.scheme, scheme == "http" else {
            return eventLoop.makeFailedFuture(WindowsHTTPClientError.unsupportedScheme(request.url.scheme ?? "(none)"))
        }
        guard let host = request.url.host, !host.isEmpty else {
            return eventLoop.makeFailedFuture(WindowsHTTPClientError.missingHost)
        }
        let port = request.url.port ?? 80

        // Build the request-line URI (path + optional query, no scheme/host).
        var uri = request.url.path.isEmpty ? "/" : request.url.path
        if let query = request.url.query, !query.isEmpty {
            uri.append("?")
            uri.append(query)
        }

        // Build the request head. Inject Host + Connection: close + Content-Length if needed.
        var headers = request.headers
        if !headers.contains(name: "Host") {
            let isDefaultPort = port == 80
            headers.add(name: "Host", value: isDefaultPort ? host : "\(host):\(port)")
        }
        if !headers.contains(name: "Connection") {
            headers.add(name: "Connection", value: "close")
        }
        if let body = request.body, !headers.contains(name: "Content-Length") {
            headers.add(name: "Content-Length", value: "\(body.readableBytes)")
        }

        let head = HTTPRequestHead(
            version: .http1_1,
            method: request.method,
            uri: uri,
            headers: headers
        )

        let responsePromise = eventLoop.makePromise(of: ClientResponse.self)

        // Open the connection.
        let bootstrap = ClientBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers(position: .first, leftOverBytesStrategy: .dropBytes).flatMap {
                    let handler = WindowsHTTPClientResponseHandler(promise: responsePromise, allocator: allocator, logger: logger)
                    return channel.pipeline.addHandler(handler)
                }
            }

        let connect = bootstrap.connect(host: host, port: port)
        connect.whenSuccess { channel in
            logger?.trace("WindowsHTTPClient connected to \(host):\(port)")
            // Queue head + optional body, then flush via writeAndFlush(.end).
            // We deliberately ignore the futures returned by the intermediate `write`
            // calls — those only complete on flush, and we flush all three parts at the
            // end. Chaining `.flatMap` between them deadlocks because the first write's
            // future waits for a flush that hasn't been issued yet.
            channel.write(HTTPClientRequestPart.head(head), promise: nil)
            if let body = request.body {
                channel.write(HTTPClientRequestPart.body(.byteBuffer(body)), promise: nil)
            }
            let writeEnd = channel.writeAndFlush(HTTPClientRequestPart.end(nil))
            writeEnd.whenSuccess { _ in
                logger?.trace("WindowsHTTPClient request sent to \(host):\(port), awaiting response")
            }
            writeEnd.whenFailure { error in
                logger?.warning("WindowsHTTPClient write failed: \(error)")
                responsePromise.fail(error)
                channel.close(promise: nil)
            }
        }
        connect.whenFailure { error in
            responsePromise.fail(error)
        }

        return responsePromise.futureResult
    }
}

// MARK: - Response handler

private final class WindowsHTTPClientResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<ClientResponse>
    private let allocator: ByteBufferAllocator
    private let logger: Logger?

    private var head: HTTPResponseHead?
    private var body: ByteBuffer?
    private var resolved: Bool = false

    init(promise: EventLoopPromise<ClientResponse>, allocator: ByteBufferAllocator, logger: Logger?) {
        self.promise = promise
        self.allocator = allocator
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head(let head):
            self.logger?.trace("WindowsHTTPClient received head: \(head.status)")
            self.head = head
        case .body(var chunk):
            self.logger?.trace("WindowsHTTPClient received body chunk: \(chunk.readableBytes) bytes")
            if self.body == nil {
                self.body = self.allocator.buffer(capacity: chunk.readableBytes)
            }
            self.body?.writeBuffer(&chunk)
        case .end:
            self.logger?.trace("WindowsHTTPClient received end")
            guard let head = self.head else {
                self.failOnce(WindowsHTTPClientError.malformedResponse)
                context.close(promise: nil)
                return
            }
            let response = ClientResponse(
                status: head.status,
                headers: head.headers,
                body: self.body,
                byteBufferAllocator: self.allocator
            )
            self.succeedOnce(response)
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.failOnce(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // If the channel closed before we resolved the promise, surface that.
        self.failOnce(WindowsHTTPClientError.connectionClosedBeforeResponse)
        context.fireChannelInactive()
    }

    private func succeedOnce(_ response: ClientResponse) {
        guard !self.resolved else { return }
        self.resolved = true
        self.promise.succeed(response)
    }

    private func failOnce(_ error: any Error) {
        guard !self.resolved else { return }
        self.resolved = true
        self.promise.fail(error)
    }
}

// MARK: - Errors

public enum WindowsHTTPClientError: Error, CustomStringConvertible {
    case unsupportedScheme(String)
    case missingHost
    case malformedResponse
    case connectionClosedBeforeResponse

    public var description: String {
        switch self {
        case .unsupportedScheme(let s):
            return "WindowsHTTPClient supports only http:// URLs; got scheme '\(s)'. For HTTPS, wait for upstream NIOSSL Swift Windows support."
        case .missingHost:
            return "WindowsHTTPClient: URL is missing a host"
        case .malformedResponse:
            return "WindowsHTTPClient: response ended without HTTP head"
        case .connectionClosedBeforeResponse:
            return "WindowsHTTPClient: connection closed before response was received"
        }
    }
}

// MARK: - Application integration (mirrors HTTP/Client/Application+HTTP+Client.swift)

extension Application.Clients.Provider {
    /// Windows-only `.http` provider that registers a `WindowsHTTPClient` as the default
    /// `app.client`. Matches the non-Windows `Application.Clients.Provider.http` API.
    public static var http: Self {
        .init {
            $0.clients.use {
                WindowsHTTPClient(
                    eventLoop: $0.eventLoopGroup.next(),
                    byteBufferAllocator: $0.core.storage.allocator,
                    logger: $0.logger
                )
            }
        }
    }
}

#endif
