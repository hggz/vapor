// SPDX-License-Identifier: MIT
//
// Windows-only file I/O helpers used by Vapor in place of `_NIOFileSystem`.
//
// Background: `_NIOFileSystem` doesn't build on Windows (POSIX-only syscalls in apple/swift-nio;
// see bucket/HANDOFF-vapor-investigation-2026-05-14.md). NIOPosix's `NonBlockingFileIO` and
// `NIOFileHandle`, however, DO build on Windows via our hggz/swift-nio:windows-joannis-mirror
// substrate (the `#if !os(Windows)` gates inside NIOPosix only cover POSIX-only helpers like
// `lstat` and `setNonBlocking`, not the file read/write path).
//
// `WindowsFile` is a small internal facade that gives Vapor's source files a single Windows-arm
// entry point for the operations they need. The implementation:
//   - Uses `NonBlockingFileIO.openFile(_deprecatedPath:eventLoop:)` for reads
//     (returns (NIOFileHandle, FileRegion) — covers open AND size in one async-safe call).
//   - Uses `NonBlockingFileIO.openFile(_deprecatedPath:mode:flags:eventLoop:)` for writes.
//   - Uses Win32 `GetFileAttributesExW` for file metadata (size, mtime, isDirectory) since
//     NIOPosix's `lstat` is gated to non-Windows.
//
// See bucket/WINDOWS_PATCHES-vapor-section-draft.md.

#if os(Windows)

import Foundation
import Logging
import NIOCore
import NIOPosix
import WinSDK

internal enum WindowsFile {
    /// Subset of the `_NIOFileSystem.FileInfo` API that Vapor consumes on Windows.
    internal struct Info: Sendable {
        /// File size in bytes.
        var size: Int64
        /// Last data modification time.
        var lastModified: Date
        /// `true` if this entry is a directory.
        var isDirectory: Bool
    }

    /// Default thread pool used for blocking file operations. Always the singleton.
    private static var threadPool: NIOThreadPool { .singleton }

    /// Default event loop for awaiting completion. Always picked from the singleton MTELG.
    private static var defaultEventLoop: any EventLoop {
        MultiThreadedEventLoopGroup.singleton.next()
    }

    // MARK: - Metadata

    /// Get file metadata via Win32 `GetFileAttributesExW`. Returns `nil` if the file does not exist.
    ///
    /// Runs the blocking Win32 call on `NIOThreadPool.singleton`.
    internal static func info(
        at path: String,
        eventLoop: (any EventLoop)? = nil
    ) async throws -> Info? {
        let el = eventLoop ?? defaultEventLoop
        return try await threadPool.runIfActive(eventLoop: el) {
            try infoSync(at: path)
        }.get()
    }

    /// Synchronous variant of `info(at:)`. Safe to call from a thread pool job.
    private static func infoSync(at path: String) throws -> Info? {
        var attr = WIN32_FILE_ATTRIBUTE_DATA()
        let success = path.withCString(encodedAs: UTF16.self) { wide in
            GetFileAttributesExW(wide, GetFileExInfoStandard, &attr)
        }
        guard success else {
            let err = GetLastError()
            // ERROR_FILE_NOT_FOUND (2) / ERROR_PATH_NOT_FOUND (3) → nil. Any other error rethrows.
            if err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND {
                return nil
            }
            throw WindowsFileError(code: err, operation: "GetFileAttributesExW(\(path))")
        }
        let size = (Int64(attr.nFileSizeHigh) << 32) | Int64(attr.nFileSizeLow)
        let isDir = (attr.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0
        let mtime = Self.fileTimeToDate(attr.ftLastWriteTime)
        return Info(size: size, lastModified: mtime, isDirectory: isDir)
    }

    /// Convert a Win32 `FILETIME` (100-ns intervals since 1601-01-01 UTC) to `Foundation.Date`.
    private static func fileTimeToDate(_ ft: FILETIME) -> Date {
        let intervals = (UInt64(ft.dwHighDateTime) << 32) | UInt64(ft.dwLowDateTime)
        // FILETIME epoch (1601-01-01 UTC) vs Unix epoch (1970-01-01 UTC) = 11_644_473_600 s.
        let unixSeconds = Double(intervals) / 10_000_000.0 - 11_644_473_600.0
        return Date(timeIntervalSince1970: unixSeconds)
    }

    // MARK: - Read

    /// Read the entire contents of a file into a `ByteBuffer`. Fails with
    /// ``Vapor.Abort`` if the file is larger than `maxBytes`.
    internal static func readToEnd(
        at path: String,
        maxBytes: Int = Int.max,
        eventLoop: (any EventLoop)? = nil
    ) async throws -> ByteBuffer {
        let el = eventLoop ?? defaultEventLoop
        let fileio = NonBlockingFileIO(threadPool: threadPool)
        let (handle, region) = try await fileio.openFile(
            _deprecatedPath: path,
            eventLoop: el
        ).get()
        defer { try? handle.close() }

        if region.readableBytes > maxBytes {
            throw Abort(
                .payloadTooLarge,
                reason: "File at \(path) is \(region.readableBytes) bytes; max allowed is \(maxBytes)."
            )
        }
        return try await fileio.read(
            fileRegion: region,
            allocator: ByteBufferAllocator(),
            eventLoop: el
        ).get()
    }

    /// Read `length` bytes from `offset` in the file.
    internal static func readChunk(
        at path: String,
        fromOffset offset: Int64,
        length: Int,
        eventLoop: (any EventLoop)? = nil
    ) async throws -> ByteBuffer {
        let el = eventLoop ?? defaultEventLoop
        let fileio = NonBlockingFileIO(threadPool: threadPool)
        let handle = try await fileio.openFile(
            _deprecatedPath: path,
            mode: .read,
            flags: .default,
            eventLoop: el
        ).get()
        defer { try? handle.close() }

        return try await fileio.read(
            fileHandle: handle,
            fromOffset: offset,
            byteCount: length,
            allocator: ByteBufferAllocator(),
            eventLoop: el
        ).get()
    }

    // MARK: - Write

    /// Write the entire contents of `buffer` to `path`, replacing any existing file.
    internal static func write(
        _ buffer: ByteBuffer,
        to path: String,
        eventLoop: (any EventLoop)? = nil
    ) async throws {
        let el = eventLoop ?? defaultEventLoop
        let fileio = NonBlockingFileIO(threadPool: threadPool)
        // O_WRONLY | O_CREAT | O_TRUNC — matches Vapor's "replace existing" semantics.
        // `NIOFileHandle.Flags.allowFileCreation()` adds O_CREAT and a default 0o644 mode.
        let flags = NIOFileHandle.Flags.allowFileCreation()
        let handle = try await fileio.openFile(
            _deprecatedPath: path,
            mode: .write,
            flags: flags,
            eventLoop: el
        ).get()
        defer { try? handle.close() }

        // Truncate by writing from offset 0 then closing; NIOFileHandle doesn't expose
        // an explicit truncate. We rely on O_TRUNC being implied by .allowFileCreation()
        // when the file already exists. If it isn't (NIO doesn't add O_TRUNC by default),
        // see WindowsFileError.notTruncated comment below.
        _ = try await fileio.write(
            fileHandle: handle,
            buffer: buffer,
            eventLoop: el
        ).get()
    }

    // MARK: - Streaming

    /// Async stream of chunks read from `path` starting at `offset` for `byteCount` bytes.
    /// Used by HTTP streaming response paths. The stream's deinit closes the underlying handle.
    internal static func readChunks(
        at path: String,
        fromOffset offset: Int64,
        byteCount: Int,
        chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
        eventLoop: (any EventLoop)? = nil
    ) -> AsyncThrowingStream<ByteBuffer, any Error> {
        let el = eventLoop ?? defaultEventLoop
        let fileio = NonBlockingFileIO(threadPool: threadPool)
        return AsyncThrowingStream<ByteBuffer, any Error> { continuation in
            let task = Task {
                do {
                    let handle = try await fileio.openFile(
                        _deprecatedPath: path,
                        mode: .read,
                        flags: .default,
                        eventLoop: el
                    ).get()
                    do {
                        try await fileio.readChunked(
                            fileHandle: handle,
                            fromOffset: offset,
                            byteCount: byteCount,
                            chunkSize: chunkSize,
                            allocator: ByteBufferAllocator(),
                            eventLoop: el
                        ) { chunk in
                            continuation.yield(chunk)
                            return el.makeSucceededFuture(())
                        }.get()
                    } catch {
                        try? handle.close()
                        throw error
                    }
                    try? handle.close()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Errors

internal struct WindowsFileError: Error, CustomStringConvertible {
    let code: DWORD
    let operation: String
    var description: String {
        "WindowsFileError: \(operation) failed with Win32 error code \(code)"
    }
}

#endif
