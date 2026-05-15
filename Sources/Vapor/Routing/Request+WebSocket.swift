// Server-side WebSocket upgrade. `WebSocket` and `WebSocketUpgrader` resolve to WebSocketKit
// on non-Windows and to Vapor's Windows-only WSCore-backed shim on Windows.
import NIOCore
#if !os(Windows)
import WebSocketKit
#endif
import NIOHTTP1

extension Request {
     @preconcurrency public func webSocket(
         maxFrameSize: WebSocketMaxFrameSize = .`default`,
         shouldUpgrade: @escaping (@Sendable (Request) -> EventLoopFuture<HTTPHeaders?>) = {
             $0.eventLoop.makeSucceededFuture([:])
         },
         onUpgrade: @Sendable @escaping (Request, WebSocket) -> ()
     ) -> Response {
         let res = Response(status: .switchingProtocols)
         res.upgrader = WebSocketUpgrader(maxFrameSize: maxFrameSize, shouldUpgrade: {
             shouldUpgrade(self)
         }, onUpgrade: { ws in
             onUpgrade(self, ws)
         })
         return res
     }
 }
