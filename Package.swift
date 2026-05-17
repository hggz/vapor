// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "vapor",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6)
    ],
    products: [
        .library(name: "Vapor", targets: ["Vapor"]),
        .library(name: "XCTVapor", targets: ["XCTVapor"]),
        .library(name: "VaporTesting", targets: ["VaporTesting"]),
    ],
    dependencies: [
        // HTTP client library built on SwiftNIO
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),

        // Sugary extensions for the SwiftNIO library
        .package(url: "https://github.com/vapor/async-kit.git", from: "1.15.0"),

        // 💻 APIs for creating interactive CLI tools.
        .package(url: "https://github.com/vapor/console-kit.git", from: "4.14.0"),

        // 🔑 Hashing (SHA2, HMAC), encryption (AES), public-key (RSA), and random data generation.
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0" ..< "5.0.0"),

        // 🚍 High-performance trie-node router.
        .package(url: "https://github.com/vapor/routing-kit.git", from: "4.9.0"),

        // Event-driven network application framework for high performance protocol servers & clients, non-blocking.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),

        // Bindings to OpenSSL-compatible libraries for TLS support in SwiftNIO
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.34.0"),

        // HTTP/2 support for SwiftNIO
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.28.0"),

        // Useful code around SwiftNIO.
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.24.0"),

        // Swift logging API
        .package(url: "https://github.com/apple/swift-log.git", from: "1.8.0"),

        // Swift metrics API
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        
        // Swift tracing API
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.1.0"),
        
        // Swift service context
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.0.0"),

        // Swift collection algorithms
        .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.0.0"),

        // WebSocket client library built on SwiftNIO
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.13.0"),

        // WSCore from swift-websocket — used ONLY on Windows as the WebSocket server runtime,
        // replacing WebSocketKit (which transitively imports the NIOSSL Swift module — gated
        // on Windows). Pinned to 1.5.0 because main branch added `import NIOSSL` to WSCore's
        // WebSocketHandler.swift after that tag; 1.5.0 keeps WSCore Windows-buildable.
        // See bucket/HANDOFF-vapor-investigation-2026-05-14.md.
        .package(url: "https://github.com/hummingbird-project/swift-websocket.git", exact: "1.5.0"),

        // MultipartKit, Multipart encoding and decoding
        .package(url: "https://github.com/vapor/multipart-kit.git", from: "4.2.1"),

        // Low-level atomic operations
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.1.0"),

        // X509 certificate types for the Swift ecosystem
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.14.0"),

        // Work with certificate encoding schemes
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0")
    ],
    targets: [
        // C helpers
        .target(name: "CVaporBcrypt"),
        
        // Vapor
        .target(
            name: "Vapor",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client",
                         condition: .when(platforms: [.macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS, .linux, .android])),
                .product(name: "AsyncKit", package: "async-kit"),
                .target(name: "CVaporBcrypt"),
                .product(name: "ConsoleKit", package: "console-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "ServiceContextModule", package: "swift-service-context"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOHTTPCompression", package: "swift-nio-extras"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                // NIOSSL Swift module now builds on Windows via the
                // hggz/swift-nio-ssl:windows-winsock-headers fork (commit 7f9efd5 / Phase E,
                // 2026-05-16). It's listed unconditionally here; gated callers in Vapor's
                // sources (HTTPServer.swift, Security/ValidatedCertificateChain.swift, etc.)
                // are also being un-gated. See bucket/WINDOWS_PATCHES-vapor-section-draft.md.
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "RoutingKit", package: "routing-kit"),
                // WebSocketKit imports NIOSSL Swift unconditionally; gated on Windows alongside
                // NIOSSL itself. Vapor's WebSocket helpers (Request.webSocket, RoutesBuilder.webSocket,
                // WebSocketUpgrader) are gated on Windows to match.
                .product(name: "WebSocketKit", package: "websocket-kit",
                         condition: .when(platforms: [.macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS, .linux, .android])),
                // WSCore (swift-websocket 1.5.0) is the Windows replacement for WebSocketKit's
                // server-side machinery. It's pulled only on Windows; Vapor's
                // Sources/Vapor/HTTP/Server/WebSocketWindows.swift uses it to provide the
                // `WebSocket` facade and `WebSocketUpgrader` that the rest of Vapor wires into.
                .product(name: "WSCore", package: "swift-websocket",
                         condition: .when(platforms: [.windows])),
                .product(name: "MultipartKit", package: "multipart-kit"),
                .product(name: "Atomics", package: "swift-atomics"),
                // _NIOFileSystem has no Windows port upstream (see HANDOFF-vapor-investigation
                // 2026-05-14): its syscalls reference POSIX-only APIs (fts(3), getpwuid_r,
                // dirent, sendfile, …). Restrict to non-Windows platforms so Vapor itself can
                // build on Windows; Vapor source files that import _NIOFileSystem are gated
                // with `#if !os(Windows)` to match.
                .product(name: "_NIOFileSystem", package: "swift-nio",
                         condition: .when(platforms: [.macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS, .linux, .android])),
                .product(name: "_NIOFileSystemFoundationCompat", package: "swift-nio",
                         condition: .when(platforms: [.macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS, .linux, .android])),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            swiftSettings: swiftSettings
        ),

        // Development
        .executableTarget(
            name: "Development",
            dependencies: [
                .target(name: "Vapor"),
            ],
            resources: [.copy("Resources")],
            swiftSettings: swiftSettings
        ),

        // Testing
        .target(
            name: "VaporTestUtils",
            dependencies: [
                .target(name: "Vapor"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VaporTesting",
            dependencies: [
                .target(name: "VaporTestUtils"),
                .target(name: "Vapor"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "XCTVapor",
            dependencies: [
                .target(name: "VaporTestUtils"),
                .target(name: "Vapor"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "VaporTests",
            dependencies: [
                .product(name: "NIOTestUtils", package: "swift-nio"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .target(name: "XCTVapor"),
                .target(name: "VaporTesting"),
                .target(name: "Vapor"),
            ],
            resources: [
                .copy("Utilities/foo.txt"),
                .copy("Utilities/index.html"),
                .copy("Utilities/SubUtilities/"),
                .copy("Utilities/foo bar.html"),
                .copy("Utilities/test.env"),
                .copy("Utilities/my-secret-env-content"),
                .copy("Utilities/expired.crt"),
                .copy("Utilities/expired.key"),
                .copy("Utilities/long-test-file.txt"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] { [
    //.enableUpcomingFeature("ExistentialAny"),
    //.enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    //.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
] }
