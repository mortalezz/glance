import Foundation
import Darwin

public struct ScanResult: Sendable {
    public let items: [SlideItem]
    public let initialIndex: Int
    public let directoryURL: URL

    public init(items: [SlideItem], initialIndex: Int, directoryURL: URL) {
        self.items = items
        self.initialIndex = initialIndex
        self.directoryURL = directoryURL
    }
}

/// Asynchronous directory scanner that gathers, sibling-stacks (RAW + JPEG),
/// and natural-sorts image files off the main thread.
public actor DirectoryScanner {
    public init() {}

    /// Scans the directory containing `targetURL` (or `targetURL` itself if it is a directory)
    /// and finds all supported images, automatically grouping paired RAW + JPEG shots into single slides.
    public func scan(targetURL: URL) async throws -> ScanResult {
        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            var isDir: ObjCBool = false

            guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
                throw NSError(domain: "DirectoryScanner", code: 404, userInfo: [
                    NSLocalizedDescriptionKey: "File does not exist at path: \(targetURL.path)"
                ])
            }

            let directoryURL: URL
            let selectedFilename: String?

            if isDir.boolValue {
                directoryURL = targetURL
                selectedFilename = nil
            } else {
                directoryURL = targetURL.deletingLastPathComponent()
                selectedFilename = targetURL.lastPathComponent
            }

            let resourceKeys: [URLResourceKey] = [
                .fileSizeKey,
                .isRegularFileKey,
                .nameKey
            ]

            let contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            )

            // Group supported files by lowercase stem (e.g. "_dsc0001")
            struct FileEntry {
                let url: URL
                let size: Int64
                let isRaw: Bool
            }

            var groups: [String: [FileEntry]] = [:]

            for fileURL in contents {
                guard SupportedFormats.isSupported(url: fileURL) else { continue }

                // Strip quarantine and corrupt launch-services attributes in background
                _ = removexattr(fileURL.path, "com.apple.quarantine", 0)
                _ = removexattr(fileURL.path, "com.apple.LaunchServices.OpenWith", 0)

                var fileSize: Int64 = 0
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                   resourceValues.isRegularFile == true {
                    fileSize = Int64(resourceValues.fileSize ?? 0)
                }

                let isRaw = SupportedFormats.isRaw(url: fileURL)
                let stem = fileURL.deletingPathExtension().lastPathComponent.lowercased()

                let entry = FileEntry(url: fileURL, size: fileSize, isRaw: isRaw)
                if groups[stem] == nil {
                    groups[stem] = [entry]
                } else {
                    groups[stem]?.append(entry)
                }
            }

            // Build SlideItems, pairing RAW + companion standard images
            var items: [SlideItem] = []

            for (_, entries) in groups {
                let rawEntries = entries.filter { $0.isRaw }
                let standardEntries = entries.filter { !$0.isRaw }
                let allURLs = entries.map { $0.url }
                let totalSize = entries.reduce(Int64(0)) { $0 + $1.size }

                if let raw = rawEntries.first, let companion = standardEntries.first {
                    // Stacking: Use fast companion JPEG for screen-bounded preview, link master RAW
                    items.append(SlideItem(
                        url: companion.url,
                        rawURL: raw.url,
                        companionURL: companion.url,
                        allURLs: allURLs,
                        fileSize: companion.size,
                        totalStackSize: totalSize
                    ))
                } else if let raw = rawEntries.first {
                    // RAW only
                    items.append(SlideItem(
                        url: raw.url,
                        rawURL: raw.url,
                        companionURL: nil,
                        allURLs: allURLs,
                        fileSize: raw.size,
                        totalStackSize: totalSize
                    ))
                } else if let standard = standardEntries.first {
                    // Standard image only (JPEG / PNG / HEIC)
                    items.append(SlideItem(
                        url: standard.url,
                        rawURL: nil,
                        companionURL: nil,
                        allURLs: allURLs,
                        fileSize: standard.size,
                        totalStackSize: totalSize
                    ))
                }
            }

            // Natural alphanumeric sort (e.g., photo1, photo2, photo10 instead of photo1, photo10, photo2)
            items.sort {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }

            // Find index of the clicked file (matches either the RAW or companion file in the stack)
            var initialIndex = 0
            if let selected = selectedFilename {
                if let foundIndex = items.firstIndex(where: { item in
                    item.allURLs.contains(where: {
                        $0.lastPathComponent.localizedCaseInsensitiveCompare(selected) == .orderedSame
                    })
                }) {
                    initialIndex = foundIndex
                }
            }

            return ScanResult(items: items, initialIndex: initialIndex, directoryURL: directoryURL)
        }.value
    }
}
