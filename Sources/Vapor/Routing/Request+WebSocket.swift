// WebSocket server upgrade requires WebSocketKit (pulls NIOSSL Swift, unbuildable on Windows).
#if !os(Windows)
import NIOCore
import WebSocketKit
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

#endif // !os(Windows)
