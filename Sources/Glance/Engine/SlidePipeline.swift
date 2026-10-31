import Foundation
import CoreGraphics

public enum SlideDirection: Sendable {
    case forward
    case backward
    case jump
}

/// Actor managing the triple/lookahead buffer cache and background preloading.
/// Supports both fast screen-bounded downscaled previews and full 1:1 actual-pixel decodes.
public actor SlidePipeline {
    private var items: [SlideItem] = []
    private var currentIndex: Int = 0
    private var maxPixelSize: Int = 3840

    /// In-memory cache of screen-bounded decoded images: [Index: DecodedImage]
    private var cache: [Int: DecodedImage] = [:]

    /// Active screen-bounded decode tasks: [Index: Task<DecodedImage, Error>]
    private var inFlightTasks: [Int: Task<DecodedImage, Error>] = [:]

    /// In-memory cache of full-resolution 1:1 images for pixel-peeping: [Index: DecodedImage]
    private var fullResCache: [Int: DecodedImage] = [:]

    /// Active full-resolution decode tasks: [Index: Task<DecodedImage, Error>]
    private var inFlightFullResTasks: [Int: Task<DecodedImage, Error>] = [:]

    private let decoder: ImageDecoder

    /// Cache radius: 1 gives triple buffering [curr-1, curr, curr+1].
    /// Setting to 2 gives 5 images [curr-2, curr-1, curr, curr+1, curr+2] for silky smooth fast-skipping.
    /// Cache radius: 8 allows instant 0ms stepping across 2 full 4-UP quads or 4 2-UP pairs ahead/behind.
    private let cacheRadius: Int = 8

    public init(decoder: ImageDecoder = ImageDecoder.shared) {
        self.decoder = decoder
    }

    /// Configures the pipeline with a new list of items and initial index.
    public func setPlaylist(items: [SlideItem], initialIndex: Int, maxPixelSize: Int) {
        cancelAllTasks()
        cache.removeAll()
        fullResCache.removeAll()

        self.items = items
        self.currentIndex = max(0, min(initialIndex, items.count - 1))
        self.maxPixelSize = maxPixelSize

        preloadWindow(around: self.currentIndex, direction: .forward)
    }

    /// Updates the screen bounding size (e.g., if window is resized or moved to another screen).
    public func updateBoundingSize(_ newSize: Int) {
        guard self.maxPixelSize != newSize else { return }
        self.maxPixelSize = newSize
        preloadWindow(around: self.currentIndex, direction: .forward)
    }

    /// Retrieves the screen-bounded decoded image for a given index (0ms from cache).
    public func getImage(at index: Int) async throws -> DecodedImage {
        guard index >= 0 && index < items.count else {
            throw NSError(domain: "SlidePipeline", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Index \(index) out of bounds."
            ])
        }

        // 1. Check cache hit
        if let cached = cache[index] {
            return cached
        }

        // 2. Check if already in flight
        if let existingTask = inFlightTasks[index] {
            return try await existingTask.value
        }

        // 3. Start high-priority decode task
        let item = items[index]
        let bounding = self.maxPixelSize
        let decoder = self.decoder

        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try decoder.decode(at: item.url, maxBoundingPixelSize: bounding)
        }

        inFlightTasks[index] = task

        do {
            let decoded = try await task.value
            cache[index] = decoded
            inFlightTasks.removeValue(forKey: index)
            return decoded
        } catch {
            inFlightTasks.removeValue(forKey: index)
            throw error
        }
    }

    /// Retrieves the 100% full-resolution unconstrained 1:1 image for pixel peeping.
    /// If the item is a stacked RAW + JPEG shot, inspects the master RAW sensor bits.
    public func getFullResolutionImage(at index: Int) async throws -> DecodedImage {
        guard index >= 0 && index < items.count else {
            throw NSError(domain: "SlidePipeline", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Index \(index) out of bounds."
            ])
        }

        let item = items[index]

        // 1. If not stacked and screen-bounded image is already not downscaled, reuse it!
        if !item.isStacked, let cached = cache[index], !cached.isDownscaled {
            return cached
        }

        // 2. Check full-res cache
        if let fullCached = fullResCache[index] {
            return fullCached
        }

        // 3. Check if current task in flight for this specific index
        if let inFlight = inFlightFullResTasks[index] {
            return try await inFlight.value
        }

        let decoder = self.decoder
        // For stacked shots, decode 100% actual device pixels from the master RAW file!
        let targetURL = item.rawURL ?? item.url

        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            // Passing 0 or nil requests 100% unconstrained native sensor resolution
            return try decoder.decode(at: targetURL, maxBoundingPixelSize: 0)
        }

        inFlightFullResTasks[index] = task

        do {
            let decoded = try await task.value
            // Keep up to 6 full-res images in RAM to comfortably peek across full 4-UP quads
            if fullResCache.count >= 6 {
                fullResCache.removeAll()
            }
            fullResCache[index] = decoded
            inFlightFullResTasks.removeValue(forKey: index)
            return decoded
        } catch {
            inFlightFullResTasks.removeValue(forKey: index)
            throw error
        }
    }

    /// Notifies the pipeline of navigation to a new index.
    public func navigate(to index: Int, direction: SlideDirection) {
        guard index >= 0 && index < items.count else { return }
        self.currentIndex = index
        // Prune full-res cache when navigating away
        if fullResCache.keys.contains(where: { abs($0 - index) > 8 }) {
            fullResCache.removeAll()
        }
        for (idx, task) in inFlightFullResTasks {
            if abs(idx - index) > 8 {
                task.cancel()
                inFlightFullResTasks.removeValue(forKey: idx)
            }
        }

        pruneAndPreload(around: index, direction: direction)
    }

    /// Removes an item at the given index and updates internal state.
    public func removeItem(at index: Int) -> Int {
        guard index >= 0 && index < items.count else { return currentIndex }

        inFlightTasks[index]?.cancel()
        inFlightTasks.removeValue(forKey: index)
        cache.removeValue(forKey: index)
        fullResCache.removeValue(forKey: index)
        inFlightFullResTasks[index]?.cancel()
        inFlightFullResTasks.removeValue(forKey: index)

        items.remove(at: index)

        var newCache: [Int: DecodedImage] = [:]
        for (k, v) in cache {
            if k < index {
                newCache[k] = v
            } else if k > index {
                newCache[k - 1] = v
            }
        }
        cache = newCache

        var newTasks: [Int: Task<DecodedImage, Error>] = [:]
        for (k, v) in inFlightTasks {
            if k < index {
                newTasks[k] = v
            } else if k > index {
                newTasks[k - 1] = v
            }
        }
        inFlightTasks = newTasks

        if items.isEmpty {
            currentIndex = 0
        } else if currentIndex >= items.count {
            currentIndex = items.count - 1
        }

        pruneAndPreload(around: currentIndex, direction: .forward)
        return currentIndex
    }

    /// Inserts an item at the given index and shifts internal cache keys appropriately.
    public func insertItem(_ item: SlideItem, at index: Int) -> Int {
        let insertIdx = max(0, min(index, items.count))
        items.insert(item, at: insertIdx)

        var newCache: [Int: DecodedImage] = [:]
        for (k, v) in cache {
            if k < insertIdx {
                newCache[k] = v
            } else {
                newCache[k + 1] = v
            }
        }
        cache = newCache

        var newTasks: [Int: Task<DecodedImage, Error>] = [:]
        for (k, v) in inFlightTasks {
            if k < insertIdx {
                newTasks[k] = v
            } else {
                newTasks[k + 1] = v
            }
        }
        inFlightTasks = newTasks

        currentIndex = insertIdx
        pruneAndPreload(around: currentIndex, direction: .forward)
        return currentIndex
    }

    /// Invalidates cached decoded representations for a specific item (e.g. after lossless rotation).
    public func invalidateCache(at index: Int) {
        cache.removeValue(forKey: index)
        fullResCache.removeValue(forKey: index)
        inFlightTasks[index]?.cancel()
        inFlightTasks.removeValue(forKey: index)
        inFlightFullResTasks[index]?.cancel()
        inFlightFullResTasks.removeValue(forKey: index)
    }

    /// Batch removes items at the given indices.
    public func removeItems(at indices: Set<Int>) {
        cancelAllTasks()
        cache.removeAll()
        fullResCache.removeAll()

        let sorted = indices.sorted(by: >)
        for idx in sorted {
            if idx >= 0 && idx < items.count {
                items.remove(at: idx)
            }
        }

        if currentIndex >= items.count {
            currentIndex = max(0, items.count - 1)
        }
        pruneAndPreload(around: currentIndex, direction: .forward)
    }

    // MARK: - Private Cache Management

    private func pruneAndPreload(around centerIndex: Int, direction: SlideDirection) {
        let validRange = (centerIndex - cacheRadius)...(centerIndex + cacheRadius)

        let keysToEvict = cache.keys.filter { !validRange.contains($0) }
        for key in keysToEvict {
            cache.removeValue(forKey: key)
        }

        let tasksToCancel = inFlightTasks.keys.filter { !validRange.contains($0) }
        for key in tasksToCancel {
            inFlightTasks[key]?.cancel()
            inFlightTasks.removeValue(forKey: key)
        }

        preloadWindow(around: centerIndex, direction: direction)
    }

    private func preloadWindow(around centerIndex: Int, direction: SlideDirection) {
        var loadOrder: [Int] = [centerIndex]

        switch direction {
        case .forward, .jump:
            for offset in 1...cacheRadius {
                loadOrder.append(centerIndex + offset)
                loadOrder.append(centerIndex - offset)
            }
        case .backward:
            for offset in 1...cacheRadius {
                loadOrder.append(centerIndex - offset)
                loadOrder.append(centerIndex + offset)
            }
        }

        for idx in loadOrder {
            guard idx >= 0 && idx < items.count else { continue }
            guard cache[idx] == nil && inFlightTasks[idx] == nil else { continue }

            let item = items[idx]
            let bounding = self.maxPixelSize
            let decoder = self.decoder

            let task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try decoder.decode(at: item.url, maxBoundingPixelSize: bounding)
            }

            inFlightTasks[idx] = task

            Task { [weak self, idx] in
                do {
                    let decoded = try await task.value
                    await self?.saveDecoded(decoded, for: idx)
                } catch {
                    await self?.taskFinished(for: idx)
                }
            }
        }
    }

    private func saveDecoded(_ decoded: DecodedImage, for index: Int) {
        let validRange = (currentIndex - cacheRadius)...(currentIndex + cacheRadius)
        if validRange.contains(index) {
            cache[index] = decoded
        }
        inFlightTasks.removeValue(forKey: index)
    }

    private func taskFinished(for index: Int) {
        inFlightTasks.removeValue(forKey: index)
    }

    private func cancelAllTasks() {
        for (_, task) in inFlightTasks {
            task.cancel()
        }
        inFlightTasks.removeAll()
        for (_, task) in inFlightFullResTasks {
            task.cancel()
        }
        inFlightFullResTasks.removeAll()
    }
}
