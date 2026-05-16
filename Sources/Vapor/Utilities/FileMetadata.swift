// SPDX-License-Identifier: MIT
//
// Platform-agnostic accessor for the bits of file metadata that Vapor's async file APIs need.
// On non-Windows this delegates to `FileSystem.shared.info(forFileAt:)` from `_NIOFileSystem`.
// On Windows it delegates to `WindowsFile.info(at:)` (Vapor's Windows shim).
//
// See bucket/HANDOFF-vapor-investigation-2026-05-14.md for the rationale.

import Foundation
#if !os(Windows)
import _NIOFileSystem
#endif

/// Internal struct giving FileIO and FileMiddleware a single API for "did the path exist,
/// and if so what's its size/mtime/isDirectory" regardless of platform.
internal struct _FileMetadata: Sendable {
    let size: Int64
    let lastModifiedDate: Date
    /// Epoch seconds. Matches `_NIOFileSystem.FileInfo.lastDataModificationTime.seconds`.
    let lastModifiedSeconds: Int64
    let isDirectory: Bool

    static func load(path: String) async throws -> _FileMetadata? {
        #if os(Windows)
        guard let info = try await WindowsFile.info(at: path) else { return nil }
        return _FileMetadata(
            size: info.size,
            lastModifiedDate: info.lastModified,
            lastModifiedSeconds: Int64(info.lastModified.timeIntervalSince1970),
            isDirectory: info.isDirectory
        )
        #else
        guard let info = try await FileSystem.shared.info(forFileAt: .init(path)) else { return nil }
        return _FileMetadata(
            size: info.size,
            lastModifiedDate: info.lastDataModificationTime.date,
            lastModifiedSeconds: info.lastDataModificationTime.seconds,
            isDirectory: info.type == .directory
        )
        #endif
    }
}
