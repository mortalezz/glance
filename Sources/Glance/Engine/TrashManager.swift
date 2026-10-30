import Foundation

public struct TrashedFileRecord: Sendable {
    public let originalURL: URL
    public let trashedURL: URL

    public init(originalURL: URL, trashedURL: URL) {
        self.originalURL = originalURL
        self.trashedURL = trashedURL
    }
}

public enum TrashManager {
    /// Moves a file to the macOS Trash asynchronously off the main thread.
    public static func moveToTrash(url: URL) async throws -> URL {
        return try await Task.detached(priority: .userInitiated) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            guard let trashedURL = resultingURL as? URL else {
                return url
            }
            return trashedURL
        }.value
    }

    /// Restores a trashed file record back to its original location.
    public static func restore(record: TrashedFileRecord) async throws {
        try await Task.detached(priority: .userInitiated) {
            let parentDir = record.originalURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: record.originalURL.path) {
                try FileManager.default.removeItem(at: record.originalURL)
            }
            try FileManager.default.moveItem(at: record.trashedURL, to: record.originalURL)
        }.value
    }
}
