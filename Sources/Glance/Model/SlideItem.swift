import Foundation
import UniformTypeIdentifiers

/// Represents a single slide item in the folder, which can be an individual photo
/// or a stacked pair of RAW + JPEG companion shots.
public struct SlideItem: Identifiable, Hashable, Sendable {
    public let id: String
    /// The primary image URL used for fast browsing and preview decode (JPEG if stacked, else RAW).
    public let url: URL
    /// The master RAW file URL if present in the stack.
    public let rawURL: URL?
    /// The companion standard preview URL (JPEG/HEIC) if stacked.
    public let companionURL: URL?
    /// All physical files belonging to this stack (RAW, companion image, etc.).
    public let allURLs: [URL]
    /// Primary filename (e.g. "_DSC0001.ARW" or "_DSC0001.JPG").
    public let filename: String
    /// Human-friendly display title (e.g. "_DSC0001.ARW + JPG" when stacked).
    public let displayName: String
    /// File size of primary preview file.
    public let fileSize: Int64
    /// Combined total size of all stacked files on disk.
    public let totalStackSize: Int64
    /// True if this slide represents a paired RAW + JPEG stack.
    public let isStacked: Bool

    public init(
        url: URL,
        rawURL: URL? = nil,
        companionURL: URL? = nil,
        allURLs: [URL]? = nil,
        fileSize: Int64 = 0,
        totalStackSize: Int64? = nil
    ) {
        self.url = url
        self.rawURL = rawURL
        self.companionURL = companionURL

        let resolvedAll: [URL]
        if let explicit = allURLs, !explicit.isEmpty {
            resolvedAll = explicit
        } else {
            var list: [URL] = []
            if let r = rawURL { list.append(r) }
            if let c = companionURL, c.path != rawURL?.path { list.append(c) }
            if list.isEmpty { list.append(url) }
            resolvedAll = list
        }
        self.allURLs = resolvedAll

        self.isStacked = (rawURL != nil && companionURL != nil && rawURL?.path != companionURL?.path)

        // Stable ID based on the master RAW or primary path
        self.id = (rawURL ?? url).path
        self.filename = (rawURL ?? url).lastPathComponent

        if self.isStacked, let raw = rawURL, let comp = companionURL {
            let compExt = comp.pathExtension.uppercased()
            self.displayName = "\(raw.lastPathComponent) + \(compExt)"
        } else {
            self.displayName = self.filename
        }

        self.fileSize = fileSize
        self.totalStackSize = totalStackSize ?? fileSize
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: SlideItem, rhs: SlideItem) -> Bool {
        lhs.id == rhs.id
    }
}
