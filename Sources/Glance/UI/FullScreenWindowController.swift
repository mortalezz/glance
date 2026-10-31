import AppKit
import CoreGraphics

@MainActor
public final class FullScreenWindowController: NSWindowController, SlideViewDelegate, NSWindowDelegate {
    private let slideView: SlideView
    private let pipeline: SlidePipeline
    private let scanner: DirectoryScanner

    private var allItems: [SlideItem] = []
    private var cullingData: [String: CullingMetadata] = [:]

    // Filter & Navigation
    private var currentFilter: CullingFilter = .all
    private var filteredIndices: [Int] = []
    private var currentFilteredPos: Int = 0

    private var autoAdvance: Bool = false
    private var isDeleting: Bool = false

    // Multi-Up View & Inspection
    private var multiUpMode: MultiUpMode = .single
    private var activeHoverSlot: Int = 1
    private var displayedMultiUpPositions: [Int] = []
    private var filterBeforeMultiUp: CullingFilter? = nil

    // Phase 3: Histogram & Clipping Warnings
    private var isHistogramVisible: Bool = false
    private var isClippingVisible: Bool = false
    private var isFocusPeakingVisible: Bool = false
    private var isExifVisible: Bool = false
    private var paneHistogramData: [Int: HistogramData] = [:]
    private var paneExifData: [Int: (exif: ExifMetadata?, dims: String, size: String?)] = [:]
    private var cachedSlotItems: [SlideItem?] = Array(repeating: nil, count: 4)
    private var cachedSlotDecoded: [DecodedImage?] = Array(repeating: nil, count: 4)

    // Phase 4: Output & Productivity
    private var isSlideshowActive: Bool = false
    private var slideshowInterval: Double = 3.0
    private var slideshowTimer: Timer? = nil

    // Auto Face & Eye Focus Jump
    private var isFaceOverlayVisible: Bool = false
    private var filterBeforePicksToggle: CullingFilter? = nil
    private var detectedFacesForCurrentSlide: [DetectedFace] = []
    private var detectedFacesForChallengerSlide: [DetectedFace] = []
    private var detectedFacesByRawIndex: [Int: [DetectedFace]] = [:]
    private var faceIndicesByRawIndex: [Int: Int] = [:]
    private var currentFaceIndex: Int = 0

    // Multi-Level Undo & Redo
    private let cullingUndoManager = CullingUndoManager.shared

    // Scene & Burst Tracking
    private var burstClusterCache: [Int: BurstBreadcrumbInfo?] = [:]
    private var burstClusterTask: Task<Void, Never>? = nil

    private var isExporting: Bool = false
    private var exportProgressText: String? = nil

    // Live directory monitoring with self-trigger suppression
    private var directoryWatcher: DirectoryWatcher? = nil
    private var pipelineMaxPixelSize: Int = 4096

    public init() {
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: screenRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]

        self.slideView = SlideView(frame: screenRect)
        self.pipeline = SlidePipeline()
        self.scanner = DirectoryScanner()

        super.init(window: window)

        window.delegate = self
        window.contentView = slideView
        slideView.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle & Opening

    public func open(targetURL: URL, startFullScreen: Bool = true) {
        guard let window = self.window else { return }

        window.makeKeyAndOrderFront(nil)
        if startFullScreen && !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        Task {
            do {
                let scanResult = try await scanner.scan(targetURL: targetURL)
                guard !scanResult.items.isEmpty else {
                    displayEmptyState("No supported images found in directory.")
                    return
                }

                self.allItems = scanResult.items
                self.cullingUndoManager.clear()
                self.burstClusterTask?.cancel()
                self.burstClusterTask = nil
                self.burstClusterCache.removeAll()

                // Concurrently load all existing Adobe XMP sidecar metadata in background
                self.cullingData = await XmpSidecarManager.loadAllSidecars(for: self.allItems)

                self.rebuildFilter(targetIndex: scanResult.initialIndex)

                let screen = window.screen ?? NSScreen.main
                let scale = screen?.backingScaleFactor ?? 2.0
                let screenSize = screen?.frame.size ?? CGSize(width: 1920, height: 1080)
                let maxPixelSize = Int(max(screenSize.width, screenSize.height) * scale)
                self.pipelineMaxPixelSize = maxPixelSize

                let rawInitial = self.currentRawIndex ?? 0
                await pipeline.setPlaylist(
                    items: self.allItems,
                    initialIndex: rawInitial,
                    maxPixelSize: maxPixelSize
                )

                // Start FSEvents live folder watcher with kernel self-suppression
                self.directoryWatcher?.stop()
                let watcher = DirectoryWatcher(directoryURL: scanResult.directoryURL)
                watcher.delegate = self
                watcher.start()
                self.directoryWatcher = watcher

                await loadAndDisplayCurrent()
            } catch {
                displayEmptyState("Error loading: \(error.localizedDescription)")
            }
        }
    }

    private var currentRawIndex: Int? {
        guard !filteredIndices.isEmpty, currentFilteredPos >= 0 && currentFilteredPos < filteredIndices.count else {
            return nil
        }
        return filteredIndices[currentFilteredPos]
    }

    private func displayEmptyState(_ message: String) {
        slideView.displayMessage(message)
    }

    // MARK: - Filter Management

    private func rebuildFilter(targetIndex: Int? = nil) {
        burstClusterTask?.cancel()
        burstClusterTask = nil
        burstClusterCache.removeAll()

        let prevRawIndex = targetIndex ?? currentRawIndex

        filteredIndices = allItems.indices.filter { idx in
            let item = allItems[idx]
            let meta = cullingData[item.id] ?? CullingMetadata()
            return currentFilter.matches(meta: meta)
        }

        if filteredIndices.isEmpty {
            currentFilteredPos = 0
        } else if let prev = prevRawIndex, let match = filteredIndices.firstIndex(of: prev) {
            currentFilteredPos = match
        } else {
            currentFilteredPos = max(0, min(currentFilteredPos, filteredIndices.count - 1))
        }
    }

    // MARK: - Navigation

    private func navigate(toFilteredPos pos: Int, direction: SlideDirection) {
        guard !filteredIndices.isEmpty else { return }
        let clamped = max(0, min(pos, filteredIndices.count - 1))
        guard clamped != currentFilteredPos || filteredIndices.count == 1 else { return }

        self.currentFilteredPos = clamped
        guard let rawIndex = currentRawIndex else { return }

        Task {
            await pipeline.navigate(to: rawIndex, direction: direction)
            await loadAndDisplayCurrent()
        }
    }

    private func loadAndDisplayCurrent() async {
        guard let rawIndex = currentRawIndex, rawIndex >= 0 && rawIndex < allItems.count else {
            displayEmptyState("No matching photos for filter '\(currentFilter.title)'. Press [ \\ ] to show all.")
            return
        }

        let slotCount = multiUpMode.rawValue
        let pagePositions: [Int]
        if multiUpMode == .single {
            pagePositions = [currentFilteredPos]
        } else {
            pagePositions = await findMultiUpPagePositions(startPos: currentFilteredPos, slotCount: slotCount)
        }
        self.displayedMultiUpPositions = pagePositions

        if activeHoverSlot > pagePositions.count {
            activeHoverSlot = 1
        }
        slideView.setHoveredSplitSlot(activeHoverSlot)

        var slotImages: [CGImage?] = Array(repeating: nil, count: 4)
        var slotSizes: [CGSize] = Array(repeating: .zero, count: 4)
        var slotInfos: [SplitPaneInfo?] = Array(repeating: nil, count: 4)
        var slotDecoded: [DecodedImage?] = Array(repeating: nil, count: 4)
        var slotItems: [SlideItem?] = Array(repeating: nil, count: 4)
        var slotPaths: [String?] = Array(repeating: nil, count: 4)

        for s in 0..<pagePositions.count {
            let pos = pagePositions[s]
            guard pos < filteredIndices.count else { continue }
            let raw = filteredIndices[pos]
            let itm = allItems[raw]
            slotItems[s] = itm
            slotPaths[s] = itm.url.path
            let m = cullingData[itm.id] ?? CullingMetadata()

            if let dec = try? await pipeline.getImage(at: raw) {
                slotDecoded[s] = dec
                slotSizes[s] = CGSize(width: dec.originalWidth, height: dec.originalHeight)

                // In multi-up mode, force neutral baseline so comparison is completely unbiased
                let activeProf = (multiUpMode != .single) ? .asShot : (m.cameraProfile ?? .asShot)
                let brand = CameraProfileEngine.detectBrand(for: itm, exif: dec.exif)
                let rendered = (activeProf != .asShot)
                    ? (CameraProfileEngine.apply(profile: activeProf, brand: brand, to: dec.image) ?? dec.image)
                    : dec.image
                slotImages[s] = rendered

                let fmtSize = itm.totalStackSize > 0
                    ? ByteCountFormatter.string(fromByteCount: itm.totalStackSize, countStyle: .file)
                    : nil
                let res = "\(dec.originalWidth) × \(dec.originalHeight)"
                paneExifData[s + 1] = (dec.exif, res, fmtSize)
            }

            if multiUpMode != .single {
                let burstInfo = burstClusterCache[pos] ?? nil
                let isSlotHero = burstInfo?.isHero ?? false
                let burstDesc: String?
                if isSlotHero {
                    burstDesc = "👑 BEST IN BURST"
                } else if let b = burstInfo {
                    burstDesc = "📸 BURST [\(b.indexInBurst)/\(b.totalInBurst)]"
                } else {
                    burstDesc = nil
                }

                let slotScore = AestheticsEngine.shared.cachedScore(for: itm.url.path)
                slotInfos[s] = SplitPaneInfo(
                    slot: s + 1,
                    filename: itm.displayName,
                    pick: m.pick,
                    rating: m.rating,
                    color: m.color,
                    isPairScouting: true,
                    aestheticScore: slotScore,
                    burstDescription: burstDesc,
                    isHero: isSlotHero
                )
            }
        }

        // Primary item under view / active slot
        let primaryIdx = min(activeHoverSlot - 1, max(0, pagePositions.count - 1))
        guard let item = slotItems[primaryIdx] ?? slotItems[0],
              let decoded = slotDecoded[primaryIdx] ?? slotDecoded[0] else {
            let info = HudInfo(
                currentIndex: currentFilteredPos,
                totalCount: filteredIndices.count,
                filename: allItems[rawIndex].displayName,
                culling: cullingData[allItems[rawIndex].id] ?? CullingMetadata(),
                autoAdvance: autoAdvance,
                errorMessage: "Failed to decode primary image"
            )
            slideView.displayImage(nil, info: info)
            return
        }

        let meta = cullingData[item.id] ?? CullingMetadata()
        let formattedSize = item.totalStackSize > 0
            ? ByteCountFormatter.string(fromByteCount: item.totalStackSize, countStyle: .file)
            : nil
        let resText = "\(decoded.originalWidth) × \(decoded.originalHeight)"
        let filterBadge = currentFilter == .all ? nil : currentFilter.title

        var hudMeta = meta
        if multiUpMode != .single {
            hudMeta.cameraProfile = .asShot
        }

        let cachedAesthetic = AestheticsEngine.shared.cachedScore(for: item.url.path)

        let primaryPos = (primaryIdx < pagePositions.count) ? pagePositions[primaryIdx] : currentFilteredPos
        var burstBreadcrumb: BurstBreadcrumbInfo? = nil
        if let cached = burstClusterCache[primaryPos] {
            burstBreadcrumb = cached
        } else {
            burstClusterTask?.cancel()
            burstClusterTask = Task { @MainActor [weak self] in
                guard let self = self else { return }
                let result = await self.computeBurstCluster(for: primaryPos)
                let activePos = (self.activeHoverSlot <= self.displayedMultiUpPositions.count)
                    ? self.displayedMultiUpPositions[self.activeHoverSlot - 1]
                    : self.currentFilteredPos
                if activePos == primaryPos {
                    self.slideView.updateBurstBreadcrumb(result)
                }
                if self.multiUpMode != .single {
                    for s in 0..<self.displayedMultiUpPositions.count {
                        let p = self.displayedMultiUpPositions[s]
                        if p < self.filteredIndices.count, let b = self.burstClusterCache[p] as? BurstBreadcrumbInfo {
                            let desc = b.isHero ? "👑 BEST IN BURST" : "📸 BURST [\(b.indexInBurst)/\(b.totalInBurst)]"
                            self.slideView.updateSlotScene(slot: s + 1, description: desc, isHero: b.isHero)
                        }
                    }
                }
            }
        }

        let info = HudInfo(
            currentIndex: currentFilteredPos,
            totalCount: filteredIndices.count,
            filename: item.displayName,
            dimensions: resText,
            fileSize: formattedSize,
            isRaw: decoded.isRaw || item.rawURL != nil,
            isStacked: item.isStacked,
            isDownscaled: decoded.isDownscaled,
            culling: hudMeta,
            autoAdvance: autoAdvance,
            filterTitle: filterBadge,
            isZoomed: slideView.isZoomed,
            exif: {
                var parsed = decoded.exif
                if parsed?.pictureControl == nil {
                    let targetURL = item.rawURL ?? item.url
                    if let extracted = CameraProfileEngine.extractCameraProfile(from: targetURL) {
                        parsed = ExifMetadata(
                            cameraMake: parsed?.cameraMake,
                            cameraModel: parsed?.cameraModel,
                            lensModel: parsed?.lensModel,
                            shutterSpeed: parsed?.shutterSpeed,
                            aperture: parsed?.aperture,
                            iso: parsed?.iso,
                            focalLength: parsed?.focalLength,
                            focalLength35mm: parsed?.focalLength35mm,
                            exposureBias: parsed?.exposureBias,
                            flashFired: parsed?.flashFired,
                            dateTimeOriginal: parsed?.dateTimeOriginal,
                            pictureControl: extracted
                        )
                    }
                }
                return parsed
            }(),
            isSlideshow: isSlideshowActive,
            slideshowInterval: slideshowInterval,
            exportProgressText: exportProgressText,
            aestheticScore: cachedAesthetic,
            burstInfo: burstBreadcrumb
        )

        self.cachedSlotItems = slotItems
        self.cachedSlotDecoded = slotDecoded

        slideView.displayMultiUp(
            images: slotImages,
            nativeSizes: slotSizes,
            splitInfos: slotInfos,
            info: info
        )

        if isFaceOverlayVisible {
            refreshFaceOverlay(for: decoded.image, faces: detectedFacesForCurrentSlide)
        }

        // Asynchronous Histogram calculations for all visible panes
        if isHistogramVisible {
            updateHistogramAsync(for: slotImages)
        }
        if isClippingVisible {
            updateClippingMaskAsync(for: slotImages)
        }
        if isFocusPeakingVisible {
            updatePeakingMaskAsync(for: slotImages)
        }

        // Face detection asynchronously across multi-up slots
        currentFaceIndex = 0
        detectedFacesForCurrentSlide = []
        detectedFacesForChallengerSlide = []
        for s in 0..<slotCount {
            guard let p = slotPaths[s], let img = slotImages[s] else { continue }
            let pos = (s < pagePositions.count) ? pagePositions[s] : (currentFilteredPos + s)
            guard pos < filteredIndices.count else { continue }
            let rIdx = filteredIndices[pos]
            Task.detached(priority: .utility) { [weak self] in
                let faces = await FaceDetectionEngine.shared.detectFaces(in: img, cacheKey: p)
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentRawIndex == rawIndex else { return }
                    self.detectedFacesByRawIndex[rIdx] = faces
                    if s == 0 {
                        self.detectedFacesForCurrentSlide = faces
                    }
                    if self.isFaceOverlayVisible && s == (self.activeHoverSlot - 1) {
                        self.refreshFaceOverlay(for: img, faces: faces)
                    }
                }
            }
        }

        // ANE Burst / Scene Similarity
        if multiUpMode != .single, let img1 = slotImages[0], let img2 = slotImages[1], let p1 = slotPaths[0], let p2 = slotPaths[1] {
            let d1 = slotDecoded[0]?.exif?.date
            let d2 = slotDecoded[1]?.exif?.date
            let dt = (d1 != nil && d2 != nil) ? abs(d2!.timeIntervalSince(d1!)) : nil
            Task.detached(priority: .utility) { [weak self] in
                let sceneResult = await SceneDetectionEngine.shared.compareScenes(
                    imageA: img1,
                    keyA: p1,
                    imageB: img2,
                    keyB: p2,
                    timeDelta: dt
                )
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentRawIndex == rawIndex else { return }
                    self.slideView.updateSlotScene(slot: 1, description: sceneResult.statusDescription)
                    self.slideView.updateSlotScene(slot: 2, description: sceneResult.statusDescription)
                }
            }
        }

        // Apple Vision Aesthetic Scoring
        if multiUpMode != .single {
            for s in 0..<slotCount {
                guard let img = slotImages[s], let path = slotPaths[s] else { continue }
                let slotNum = s + 1
                Task.detached(priority: .utility) { [weak self] in
                    let score = await AestheticsEngine.shared.computeScore(for: img, cacheKey: path)
                    await MainActor.run { [weak self] in
                        guard let self = self, self.currentRawIndex == rawIndex else { return }
                        self.slideView.updateSlotAesthetics(slot: slotNum, score: score)
                    }
                }
            }
        } else if let img = slotImages[0], let path = slotPaths[0] {
            Task.detached(priority: .utility) { [weak self] in
                let score = await AestheticsEngine.shared.computeScore(for: img, cacheKey: path)
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentRawIndex == rawIndex else { return }
                    self.slideView.updateAestheticScore(score)
                }
            }
        }
    }

    // MARK: - SlideViewDelegate Navigation

    public func slideViewRequestNext() {
        stopSlideshowIfRunning()
        guard !filteredIndices.isEmpty else { return }

        if multiUpMode == .single {
            let nextPos = currentFilteredPos + 1
            if nextPos < filteredIndices.count {
                navigate(toFilteredPos: nextPos, direction: .forward)
            } else {
                navigate(toFilteredPos: 0, direction: .forward)
            }
        } else {
            let advanceCount = max(1, displayedMultiUpPositions.count)
            let nextPos = currentFilteredPos + advanceCount
            if nextPos < filteredIndices.count {
                navigate(toFilteredPos: nextPos, direction: .forward)
            } else {
                slideView.showToast("End of Set", icon: "🛑")
            }
        }
    }

    public func slideViewRequestPrevious() {
        stopSlideshowIfRunning()
        guard !filteredIndices.isEmpty else { return }

        if multiUpMode == .single {
            let prevPos = currentFilteredPos - 1
            if prevPos >= 0 {
                navigate(toFilteredPos: prevPos, direction: .backward)
            } else {
                navigate(toFilteredPos: filteredIndices.count - 1, direction: .backward)
            }
        } else {
            guard currentFilteredPos > 0 else {
                slideView.showToast("First Photo in Set", icon: "🛑")
                return
            }
            let prevTarget = currentFilteredPos - 1
            if let prevBurst = burstClusterCache[prevTarget] as? BurstBreadcrumbInfo, prevBurst.totalInBurst > 1 {
                let clusterStart = prevTarget - (prevBurst.indexInBurst - 1)
                let burstCountSoFar = prevTarget - clusterStart + 1
                let remainder = burstCountSoFar % multiUpMode.rawValue
                let stride = (remainder == 0) ? multiUpMode.rawValue : remainder
                let targetPos = max(0, prevTarget - stride + 1)
                navigate(toFilteredPos: targetPos, direction: .backward)
            } else {
                var targetPos = prevTarget
                var count = 1
                while count < multiUpMode.rawValue && targetPos > 0 {
                    let cand = targetPos - 1
                    if let cb = burstClusterCache[cand] as? BurstBreadcrumbInfo, cb.totalInBurst > 1 { break }
                    targetPos = cand
                    count += 1
                }
                navigate(toFilteredPos: targetPos, direction: .backward)
            }
        }
    }

    public func slideViewCommitSplitMatchup() {
        slideViewRequestNext()
    }

    public func slideViewRequestFirst() {
        stopSlideshowIfRunning()
        navigate(toFilteredPos: 0, direction: .jump)
    }

    public func slideViewRequestLast() {
        stopSlideshowIfRunning()
        guard !filteredIndices.isEmpty else { return }
        navigate(toFilteredPos: filteredIndices.count - 1, direction: .jump)
    }

    // MARK: - Scene Leap Navigation (Same Scene & Burst Traversal)

    private var isSceneLeaping: Bool = false

    /// Determines the exact list of filtered positions to display across multi-up slots,
    /// ensuring bursts stay unified on a single screen without fracturing across pages.
    private func findMultiUpPagePositions(startPos: Int, slotCount: Int) async -> [Int] {
        guard startPos >= 0, startPos < filteredIndices.count else { return [] }
        guard slotCount > 1 else { return [startPos] }

        var positions: [Int] = [startPos]

        // 1. Check if startPos belongs to a burst cluster
        let startBurst: BurstBreadcrumbInfo?
        if let cached = burstClusterCache[startPos] {
            startBurst = cached
        } else {
            startBurst = await computeBurstCluster(for: startPos)
        }

        if let burst = startBurst, burst.totalInBurst > 1 {
            // startPos is part of a burst! Keep the burst unified on this page
            let clusterStart = startPos - (burst.indexInBurst - 1)
            let clusterEnd = clusterStart + burst.totalInBurst - 1
            let endBound = min(clusterEnd, filteredIndices.count - 1)

            if startPos < endBound {
                for p in (startPos + 1)...endBound {
                    if positions.count < slotCount {
                        positions.append(p)
                    } else {
                        break
                    }
                }
            }
            return positions
        }

        // 2. startPos is an isolated shot. Pack subsequent isolated shots until a new burst boundary
        for offset in 1..<slotCount {
            let nextPos = startPos + offset
            guard nextPos < filteredIndices.count else { break }

            let nextBurst: BurstBreadcrumbInfo?
            if let cached = burstClusterCache[nextPos] {
                nextBurst = cached
            } else {
                nextBurst = await computeBurstCluster(for: nextPos)
            }
            if let nb = nextBurst, nb.totalInBurst > 1 {
                // Next position begins a burst series; stop packing so the burst starts fresh on next page
                break
            }
            positions.append(nextPos)
        }

        return positions
    }

    /// Checks whether two photos at filtered positions posA and posB belong to the same scene or burst.
    private func areItemsInSameScene(posA: Int, posB: Int) async -> Bool {
        guard posA >= 0, posA < filteredIndices.count,
              posB >= 0, posB < filteredIndices.count else { return false }

        let rawA = filteredIndices[posA]
        let rawB = filteredIndices[posB]
        let itemA = allItems[rawA]
        let itemB = allItems[rawB]

        // 1. Fetch decoded previews if available or decode preview
        let decA = try? await pipeline.getImage(at: rawA)
        let decB = try? await pipeline.getImage(at: rawB)

        // 2. Compute timestamp delta
        var timeDelta: TimeInterval? = nil
        if let d1 = decA?.exif?.date, let d2 = decB?.exif?.date {
            timeDelta = abs(d2.timeIntervalSince(d1))
        } else {
            let dateA = (try? itemA.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let dateB = (try? itemB.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let da = dateA, let db = dateB {
                timeDelta = abs(db.timeIntervalSince(da))
            }
        }

        // If photos were taken > 20s apart, they are unequivocally different setups/scenes
        if let dt = timeDelta, dt > 20.0 {
            return false
        }

        guard let imgA = decA?.image, let imgB = decB?.image else {
            return (timeDelta ?? 999.0) <= 3.0
        }

        let result = await SceneDetectionEngine.shared.compareScenes(
            imageA: imgA,
            keyA: itemA.url.path,
            imageB: imgB,
            keyB: itemB.url.path,
            timeDelta: timeDelta
        )

        return result.isSameScene
    }

    /// Finds the target position of the next (forward) or previous (backward) scene boundary.
    private func findSceneBoundary(from startPos: Int, forward: Bool) async -> Int? {
        let count = filteredIndices.count
        guard count > 1 else { return nil }

        if forward {
            var p = startPos
            while p + 1 < count {
                let isSame = await areItemsInSameScene(posA: p, posB: p + 1)
                if !isSame {
                    // Next scene starts at p + 1
                    return p + 1
                }
                p += 1
                if p - startPos > 80 { break } // Safeguard for giant bursts
            }
            return (p > startPos) ? p : nil
        } else {
            // Backward: If we are in the middle of a burst, first leap to the start of current burst
            var p = startPos
            while p > 0 {
                let isSame = await areItemsInSameScene(posA: p - 1, posB: p)
                if isSame {
                    p -= 1
                } else {
                    break
                }
            }

            // If we were already at the start of current burst, leap to the start of the previous burst
            if p == startPos && p > 0 {
                p -= 1
                while p > 0 {
                    let isSame = await areItemsInSameScene(posA: p - 1, posB: p)
                    if isSame {
                        p -= 1
                    } else {
                        break
                    }
                }
            }

            return (p != startPos) ? p : nil
        }
    }

    public func slideViewRequestNextScene() {
        stopSlideshowIfRunning()
        guard !filteredIndices.isEmpty else { return }
        guard !isSceneLeaping else { return }
        isSceneLeaping = true

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        Task {
            defer { self.isSceneLeaping = false }
            let startPos = self.currentFilteredPos
            guard startPos + 1 < self.filteredIndices.count else {
                self.slideView.showToast("Last Scene in Set", icon: "🛑", shortcut: "]")
                return
            }

            let nextScenePos = await self.findSceneBoundary(from: startPos, forward: true)
            let targetPos = nextScenePos ?? (self.filteredIndices.count - 1)

            await MainActor.run {
                if targetPos != startPos {
                    self.navigate(toFilteredPos: targetPos, direction: .forward)
                    self.slideView.showToast("Next Scene", icon: "⚡", shortcut: "]", tint: .systemCyan)
                } else {
                    self.slideView.showToast("Last Scene in Set", icon: "🛑", shortcut: "]")
                }
            }
        }
    }

    public func slideViewRequestPreviousScene() {
        stopSlideshowIfRunning()
        guard !filteredIndices.isEmpty else { return }
        guard !isSceneLeaping else { return }
        isSceneLeaping = true

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        Task {
            defer { self.isSceneLeaping = false }
            let startPos = self.currentFilteredPos
            guard startPos > 0 else {
                self.slideView.showToast("First Scene in Set", icon: "🛑", shortcut: "[")
                return
            }

            let prevScenePos = await self.findSceneBoundary(from: startPos, forward: false)
            let targetPos = prevScenePos ?? 0

            await MainActor.run {
                if targetPos != startPos {
                    self.navigate(toFilteredPos: targetPos, direction: .backward)
                    self.slideView.showToast("Previous Scene", icon: "⚡", shortcut: "[", tint: .systemCyan)
                } else {
                    self.slideView.showToast("First Scene in Set", icon: "🛑", shortcut: "[")
                }
            }
        }
    }

    private func getItemDate(filteredPos: Int) async -> Date? {
        guard filteredPos >= 0, filteredPos < filteredIndices.count else { return nil }
        let raw = filteredIndices[filteredPos]
        let item = allItems[raw]
        if let dec = try? await pipeline.getImage(at: raw), let d = dec.exif?.date {
            return d
        }
        return (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Scans backwards and forwards around pos to compute burst cluster indices and deltas.
    private func computeBurstCluster(for targetPos: Int) async -> BurstBreadcrumbInfo? {
        guard targetPos >= 0, targetPos < filteredIndices.count else { return nil }
        if let cached = burstClusterCache[targetPos] {
            return cached
        }

        let count = filteredIndices.count
        guard count > 1 else {
            burstClusterCache[targetPos] = nil
            return nil
        }

        // 1. Scan backwards
        var startPos = targetPos
        while startPos > 0 {
            let isSame = await areItemsInSameScene(posA: startPos - 1, posB: startPos)
            if isSame {
                startPos -= 1
            } else {
                break
            }
            if targetPos - startPos >= 60 { break } // Safeguard for extreme bursts
        }

        // 2. Scan forwards
        var endPos = targetPos
        while endPos + 1 < count {
            let isSame = await areItemsInSameScene(posA: endPos, posB: endPos + 1)
            if isSame {
                endPos += 1
            } else {
                break
            }
            if endPos - targetPos >= 60 { break }
        }

        let totalInBurst = endPos - startPos + 1
        guard totalInBurst > 1 else {
            burstClusterCache[targetPos] = nil
            return nil
        }

        // 3. Pre-fetch timestamps across the cluster for accurate Δ
        var dates: [Int: Date] = [:]
        for p in startPos...endPos {
            if let d = await getItemDate(filteredPos: p) {
                dates[p] = d
            }
        }

        // 3b. Evaluate Vision AI aesthetic/quality scores for burst frames
        var scores: [Int: AestheticScoreResult] = [:]
        for p in startPos...endPos {
            guard p < filteredIndices.count else { continue }
            let raw = filteredIndices[p]
            let itm = allItems[raw]
            if let cached = AestheticsEngine.shared.cachedScore(for: itm.url.path) {
                scores[p] = cached
            } else if let dec = try? await pipeline.getImage(at: raw) {
                let score = await AestheticsEngine.shared.computeScore(for: dec.image, cacheKey: itm.url.path)
                scores[p] = score
            }
        }

        // 3c. Crown the Burst Hero
        var bestPos: Int? = nil
        var bestScore: Float = -999.0
        var bestSharpness: Float = -1.0

        for p in startPos...endPos {
            if let sc = scores[p] {
                let effectiveScore = sc.isUtility ? (sc.score - 4.0) : sc.score
                if effectiveScore > bestScore || (abs(effectiveScore - bestScore) < 0.15 && sc.sharpnessScore > bestSharpness) {
                    bestScore = effectiveScore
                    bestSharpness = sc.sharpnessScore
                    bestPos = p
                }
            }
        }

        let heroPos = bestPos ?? startPos
        let heroIndexInBurst = (heroPos - startPos) + 1

        // 4. Populate cache for the entire cluster
        for p in startPos...endPos {
            let k = (p - startPos) + 1
            let isHero = (p == heroPos)
            var dt: TimeInterval? = nil
            if p > startPos, let dCurr = dates[p], let dPrev = dates[p - 1] {
                dt = abs(dCurr.timeIntervalSince(dPrev))
            } else if p == startPos, let dCurr = dates[p], let dNext = dates[p + 1] {
                dt = abs(dNext.timeIntervalSince(dCurr))
            }
            let info = BurstBreadcrumbInfo(
                indexInBurst: k,
                totalInBurst: totalInBurst,
                timeDelta: dt,
                isHero: isHero,
                heroIndex: heroIndexInBurst
            )
            burstClusterCache[p] = info
        }

        return burstClusterCache[targetPos] ?? nil
    }

    public func slideViewRequestJumpToHero() {
        stopSlideshowIfRunning()
        guard !filteredIndices.isEmpty else { return }

        let currentPos = currentFilteredPos
        guard let burst = burstClusterCache[currentPos] as? BurstBreadcrumbInfo, burst.totalInBurst > 1 else {
            slideView.showToast("No Burst Cluster", icon: "📸")
            return
        }

        if burst.isHero {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            slideView.showToast("Already on Burst Hero [ \(burst.indexInBurst) / \(burst.totalInBurst) ]", icon: "👑", shortcut: "B", tint: NSColor(srgbRed: 1.0, green: 0.84, blue: 0.25, alpha: 1.0))
            return
        }

        guard let heroIdx = burst.heroIndex else {
            slideView.showToast("Evaluating Burst Hero...", icon: "👑", tint: NSColor(srgbRed: 1.0, green: 0.84, blue: 0.25, alpha: 1.0))
            return
        }

        let clusterStart = currentPos - (burst.indexInBurst - 1)
        let heroTargetPos = clusterStart + (heroIdx - 1)

        guard heroTargetPos >= 0, heroTargetPos < filteredIndices.count else { return }

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        navigate(toFilteredPos: heroTargetPos, direction: (heroTargetPos > currentPos) ? .forward : .backward)
        slideView.showToast("Jumped to Hero [ \(heroIdx) / \(burst.totalInBurst) ]", icon: "👑", shortcut: "B", tint: NSColor(srgbRed: 1.0, green: 0.84, blue: 0.25, alpha: 1.0))
    }

    public func slideViewRequestDelete() {
        stopSlideshowIfRunning()
        let targetPos = (multiUpMode != .single && activeHoverSlot <= displayedMultiUpPositions.count)
            ? displayedMultiUpPositions[activeHoverSlot - 1]
            : currentFilteredPos
        guard targetPos < filteredIndices.count, !isDeleting else { return }
        let rawIndex = filteredIndices[targetPos]
        let itemToDelete = allItems[rawIndex]
        let previousMeta = cullingData[itemToDelete.id]
        isDeleting = true

        Task {
            do {
                var trashedRecords: [TrashedFileRecord] = []
                for fileURL in itemToDelete.allURLs {
                    let trashed = try await TrashManager.moveToTrash(url: fileURL)
                    trashedRecords.append(TrashedFileRecord(originalURL: fileURL, trashedURL: trashed))
                    if let sidecarURL = XmpSidecarManager.existingSidecarURL(for: fileURL) {
                        if let trashedSidecar = try? await TrashManager.moveToTrash(url: sidecarURL) {
                            trashedRecords.append(TrashedFileRecord(originalURL: sidecarURL, trashedURL: trashedSidecar))
                        }
                    }
                }

                self.cullingUndoManager.record(.delete(
                    item: itemToDelete,
                    rawIndex: rawIndex,
                    previousMeta: previousMeta,
                    trashedRecords: trashedRecords
                ))

                _ = await self.pipeline.removeItem(at: rawIndex)
                self.allItems.remove(at: rawIndex)
                self.cullingData.removeValue(forKey: itemToDelete.id)

                self.rebuildFilter()
                self.isDeleting = false

                if self.allItems.isEmpty {
                    self.displayEmptyState("Directory is now empty.")
                } else {
                    await self.loadAndDisplayCurrent()
                }
                self.slideView.showToast("Moved to Trash", icon: "🗑️", shortcut: "⌘Z to Undo", tint: .systemRed)
            } catch {
                self.isDeleting = false
                self.displayEmptyState("Failed to trash: \(error.localizedDescription)")
            }
        }
    }

    public func slideViewRequestPurgeRejects() {
        stopSlideshowIfRunning()
        let rejectedItems = allItems.filter { item in
            let meta = cullingData[item.id] ?? CullingMetadata()
            return meta.pick == .reject
        }

        guard !rejectedItems.isEmpty else {
            slideView.showToast("No Rejected Photos to Purge", icon: "🧹")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Purge \(rejectedItems.count) Rejected Photos?"
        alert.informativeText = "These files and their Adobe XMP sidecars will be moved directly to the macOS Trash. This operation can be undone via ⌘Z."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                var trashedCount = 0
                for item in rejectedItems {
                    if let idx = self.allItems.firstIndex(where: { $0.id == item.id }) {
                        for url in item.allURLs {
                            _ = try? await TrashManager.moveToTrash(url: url)
                        }
                        if let sidecar = XmpSidecarManager.existingSidecarURL(for: item.url) {
                            _ = try? await TrashManager.moveToTrash(url: sidecar)
                        }
                        _ = await self.pipeline.removeItem(at: idx)
                        self.allItems.remove(at: idx)
                        self.cullingData.removeValue(forKey: item.id)
                        trashedCount += 1
                    }
                }
                self.rebuildFilter()
                await self.loadAndDisplayCurrent()
                self.slideView.showToast("Purged \(trashedCount) Rejected Photos", icon: "🧹", tint: .systemRed)
            }
        }
    }

    // MARK: - Synchronized Multi-Up 100% Zoom & Pan Mechanics

    public func slideViewRequestZoomToggle(mouseLocation: CGPoint) {
        stopSlideshowIfRunning()
        if slideView.isZoomed {
            currentFaceIndex = 0
            slideView.setZoom(false)
        } else {
            guard currentRawIndex != nil else { return }

            let targetSlot: Int
            let slotOffset: Int
            if multiUpMode == .single {
                targetSlot = 1
                slotOffset = 0
            } else {
                targetSlot = slideView.hoveredSplitSlot
                slotOffset = max(0, min(multiUpMode.rawValue - 1, targetSlot - 1))
            }

            let targetFilteredPos = (slotOffset < displayedMultiUpPositions.count)
                ? displayedMultiUpPositions[slotOffset]
                : currentFilteredPos
            guard targetFilteredPos < filteredIndices.count else { return }
            let targetRawIndex = filteredIndices[targetFilteredPos]

            // Instantly zoom the view using the screen-bounded layer (0ms latency!)
            slideView.setZoom(true, anchorPointInView: mouseLocation, targetPaneIndex: slotOffset)

            if multiUpMode == .fourUp {
                // Option B: Solo full-screen 100% loupe for targetSlot only
                Task {
                    if let dec = try? await self.pipeline.getFullResolutionImage(at: targetRawIndex) {
                        guard self.slideView.isZoomed else { return }
                        let dims = CGSize(width: dec.originalWidth, height: dec.originalHeight)
                        self.slideView.setZoom(
                            true,
                            anchorPointInView: mouseLocation,
                            targetPaneIndex: slotOffset,
                            fullResImage: (slotOffset == 0) ? dec.image : nil,
                            originalDimensions: (slotOffset == 0) ? dims : nil,
                            rightFullResImage: (slotOffset == 1) ? dec.image : nil,
                            rightOriginalDimensions: (slotOffset == 1) ? dims : nil,
                            multiFullResImages: (0..<4).map { $0 == slotOffset ? dec.image : nil },
                            multiOriginalDimensions: (0..<4).map { $0 == slotOffset ? dims : .zero }
                        )
                    }
                }
            } else {
                var rawIndicesToFetch: [Int: Int] = [:] // [slot: rawIndex]
                for s in 0..<displayedMultiUpPositions.count {
                    let pos = displayedMultiUpPositions[s]
                    if pos < filteredIndices.count {
                        rawIndicesToFetch[s] = filteredIndices[pos]
                    }
                }

                Task {
                    var fullImages: [CGImage?] = Array(repeating: nil, count: 4)
                    var fullDims: [CGSize] = Array(repeating: .zero, count: 4)

                    await withTaskGroup(of: (Int, DecodedImage?).self) { group in
                        for (slot, rIdx) in rawIndicesToFetch {
                            group.addTask {
                                let dec = try? await self.pipeline.getFullResolutionImage(at: rIdx)
                                return (slot, dec)
                            }
                        }
                        for await (slot, dec) in group {
                            if let dec = dec {
                                fullImages[slot] = dec.image
                                fullDims[slot] = CGSize(width: dec.originalWidth, height: dec.originalHeight)
                            }
                        }
                    }

                    guard self.slideView.isZoomed else { return }

                    self.slideView.setZoom(
                        true,
                        anchorPointInView: mouseLocation,
                        targetPaneIndex: slotOffset,
                        fullResImage: fullImages[0],
                        originalDimensions: fullDims[0],
                        rightFullResImage: fullImages[1],
                        rightOriginalDimensions: fullDims[1],
                        multiFullResImages: fullImages,
                        multiOriginalDimensions: fullDims
                    )
                }
            }
        }
    }

    // MARK: - Auto Face & Eye Focus Jump

    // MARK: - Face & Eye Focus Inspection Overlay (Narrative Select Style)

    public func slideViewToggleFaceOverlay() {
        isFaceOverlayVisible.toggle()
        slideView.setFaceOverlayVisible(isFaceOverlayVisible)
        if isFaceOverlayVisible {
            slideView.showToast("Face Inspection On", icon: "👥", shortcut: "A", tint: .systemCyan)
            refreshFaceOverlay()
        } else {
            slideView.showToast("Face Inspection Off", icon: "👥", shortcut: "A")
        }
    }

    public func slideViewJumpToFace(index: Int) {
        let slotOffset: Int
        if multiUpMode == .single {
            slotOffset = 0
        } else {
            let targetSlot = activeHoverSlot
            slotOffset = max(0, min(multiUpMode.rawValue - 1, targetSlot - 1))
        }

        let targetFilteredPos = (slotOffset < displayedMultiUpPositions.count)
            ? displayedMultiUpPositions[slotOffset]
            : currentFilteredPos
        guard targetFilteredPos < filteredIndices.count else { return }
        let targetRawIndex = filteredIndices[targetFilteredPos]

        let faces = self.detectedFacesByRawIndex[targetRawIndex] ?? self.detectedFacesForCurrentSlide
        guard index >= 1, index <= faces.count else { return }
        let face = faces[index - 1]

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let label = "👁️ Face \(index)/\(faces.count) (Eye Focus)"
        slideView.zoomToNormalizedPoint(face.eyeCenter, targetPaneIndex: slotOffset, label: label)

        Task {
            if let fullDec = try? await self.pipeline.getFullResolutionImage(at: targetRawIndex) {
                guard self.slideView.isZoomed else { return }
                let dims = CGSize(width: fullDec.originalWidth, height: fullDec.originalHeight)
                self.slideView.zoomToNormalizedPoint(
                    face.eyeCenter,
                    targetPaneIndex: slotOffset,
                    fullResImage: (slotOffset == 0) ? fullDec.image : nil,
                    originalDimensions: (slotOffset == 0) ? dims : nil,
                    rightFullResImage: (slotOffset == 1) ? fullDec.image : nil,
                    rightOriginalDimensions: (slotOffset == 1) ? dims : nil,
                    label: nil
                )
            }
        }
    }

    private func refreshFaceOverlay(for cgImage: CGImage? = nil, faces: [DetectedFace]? = nil) {
        guard isFaceOverlayVisible else { return }

        let activePos = (activeHoverSlot <= displayedMultiUpPositions.count)
            ? displayedMultiUpPositions[activeHoverSlot - 1]
            : currentFilteredPos
        guard activePos < filteredIndices.count else {
            slideView.updateFaceTiles([])
            return
        }

        let rIdx = filteredIndices[activePos]
        let item = allItems[rIdx]

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            let faceList: [DetectedFace]
            if let f = faces {
                faceList = f
            } else if let cached = self.detectedFacesByRawIndex[rIdx] {
                faceList = cached
            } else if let dec = try? await self.pipeline.getImage(at: rIdx) {
                let detected = await FaceDetectionEngine.shared.detectFaces(in: dec.image, cacheKey: item.url.path)
                self.detectedFacesByRawIndex[rIdx] = detected
                faceList = detected
            } else {
                faceList = []
            }

            guard !faceList.isEmpty else {
                self.slideView.updateFaceTiles([])
                return
            }

            let img: CGImage?
            if let i = cgImage {
                img = i
            } else if let dec = try? await self.pipeline.getImage(at: rIdx) {
                img = dec.image
            } else {
                img = nil
            }

            guard let image = img else {
                self.slideView.updateFaceTiles([])
                return
            }

            let W = CGFloat(image.width)
            let H = CGFloat(image.height)
            var tiles: [FaceTileData] = []

            for (i, face) in faceList.prefix(8).enumerated() {
                let eyeX = face.eyeCenter.x * W
                let eyeY = (1.0 - face.eyeCenter.y) * H
                let boxW = face.boundingBox.width * W
                let boxH = face.boundingBox.height * H
                let cropDim = max(140.0, max(boxW, boxH) * 1.5)

                let cropOriginX = max(0, min(W - cropDim, eyeX - cropDim / 2.0))
                let cropOriginY = max(0, min(H - cropDim, eyeY - cropDim / 2.0))
                let cropW = min(cropDim, W - cropOriginX)
                let cropH = min(cropDim, H - cropOriginY)

                let cropRect = CGRect(x: cropOriginX, y: cropOriginY, width: cropW, height: cropH)
                guard let cropped = image.cropping(to: cropRect) else { continue }

                let isSharp = (face.leftEye != nil || face.rightEye != nil)
                let hasEyes = (face.leftEye != nil && face.rightEye != nil)

                tiles.append(FaceTileData(
                    index: i + 1,
                    image: cropped,
                    eyeCenterNormalized: face.eyeCenter,
                    isEyeSharp: isSharp,
                    hasOpenEyes: hasEyes,
                    confidence: face.confidence
                ))
            }

            self.slideView.updateFaceTiles(tiles)
        }
    }

    public func slideViewJumpToFaceEye() {
        stopSlideshowIfRunning()

        let targetSlot: Int
        let slotOffset: Int
        if multiUpMode == .single {
            targetSlot = 1
            slotOffset = 0
        } else {
            targetSlot = slideView.hoveredSplitSlot
            slotOffset = max(0, min(multiUpMode.rawValue - 1, targetSlot - 1))
        }

        let targetFilteredPos = (slotOffset < displayedMultiUpPositions.count)
            ? displayedMultiUpPositions[slotOffset]
            : currentFilteredPos
        guard targetFilteredPos < filteredIndices.count else { return }
        let targetRawIndex = filteredIndices[targetFilteredPos]
        let item = allItems[targetRawIndex]

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        Task {
            var faces = self.detectedFacesByRawIndex[targetRawIndex] ?? []
            if faces.isEmpty {
                if let decoded = try? await self.pipeline.getImage(at: targetRawIndex) {
                    faces = await FaceDetectionEngine.shared.detectFaces(in: decoded.image, cacheKey: item.url.path)
                    self.detectedFacesByRawIndex[targetRawIndex] = faces
                }
            }

            guard !faces.isEmpty else {
                let noFaceMsg = (self.multiUpMode != .single) ? "No faces in [\(targetSlot)]" : "No faces detected in frame"
                self.slideView.showToast(noFaceMsg, icon: "👁️", shortcut: "⇧Z")
                if !self.slideView.isZoomed {
                    let mouseInWindow = self.window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: self.slideView.bounds.midX, y: self.slideView.bounds.midY)
                    let localPt = self.slideView.convert(mouseInWindow, from: nil)
                    self.slideView.setZoom(true, anchorPointInView: localPt, targetPaneIndex: slotOffset)
                }
                return
            }

            let nextIdx = (self.faceIndicesByRawIndex[targetRawIndex] ?? 0)
            self.faceIndicesByRawIndex[targetRawIndex] = nextIdx + 1
            let currentFace = faces[nextIdx % faces.count]

            let label: String
            if self.multiUpMode != .single {
                label = faces.count > 1
                    ? "👁️ [\(targetSlot)] Face \((nextIdx % faces.count) + 1)/\(faces.count) (Eye Focus)"
                    : "👁️ [\(targetSlot)] Eye Focus"
            } else {
                label = faces.count > 1
                    ? "👁️ Face \((nextIdx % faces.count) + 1)/\(faces.count) (Eye Focus)"
                    : "👁️ Eye Focus"
            }

            let eyePoint = currentFace.eyeCenter
            self.slideView.zoomToNormalizedPoint(
                eyePoint,
                targetPaneIndex: slotOffset,
                label: label
            )

            // Concurrently fetch full resolution sensor data for the target image
            if let fullDec = try? await self.pipeline.getFullResolutionImage(at: targetRawIndex) {
                let dims = CGSize(width: fullDec.originalWidth, height: fullDec.originalHeight)
                self.slideView.zoomToNormalizedPoint(
                    eyePoint,
                    targetPaneIndex: slotOffset,
                    fullResImage: (slotOffset == 0) ? fullDec.image : nil,
                    originalDimensions: (slotOffset == 0) ? dims : nil,
                    rightFullResImage: (slotOffset == 1) ? fullDec.image : nil,
                    rightOriginalDimensions: (slotOffset == 1) ? dims : nil,
                    label: nil
                )
            }
        }
    }

    // MARK: - Phase 3: Histogram & Exposure Clipping Controls

    public func slideViewToggleHistogram() {
        isHistogramVisible.toggle()
        slideView.setHistogramVisible(isHistogramVisible)
        slideView.showToast(isHistogramVisible ? "RGB Histogram: ON" : "RGB Histogram: OFF", icon: "📊", shortcut: "H")

        if isHistogramVisible {
            Task {
                await loadAndDisplayCurrent()
            }
        }
    }

    public func slideViewToggleExif() {
        isExifVisible.toggle()
        slideView.setExifVisible(isExifVisible)
        slideView.showToast(isExifVisible ? "EXIF Info: ON" : "EXIF Info: OFF", icon: "ℹ️", shortcut: "I")
    }

    public func slideViewToggleClipping() {
        isClippingVisible.toggle()
        slideView.setClippingActive(isClippingVisible)
        slideView.showToast(isClippingVisible ? "Clipping Warnings: ON" : "Clipping Warnings: OFF", icon: "⚠️", shortcut: "O")

        if isClippingVisible {
            Task {
                await loadAndDisplayCurrent()
            }
        } else {
            slideView.updateClippingMasks([nil, nil, nil, nil])
        }
    }

    public func slideViewToggleFocusPeaking() {
        isFocusPeakingVisible.toggle()
        slideView.setPeakingActive(isFocusPeakingVisible)
        slideView.showToast(isFocusPeakingVisible ? "Focus Peaking: ON" : "Focus Peaking: OFF", icon: "🎯", shortcut: "⇧F")

        if isFocusPeakingVisible {
            Task {
                await loadAndDisplayCurrent()
            }
        } else {
            slideView.updatePeakingMasks([nil, nil, nil, nil])
        }
    }

    private func updateCullingDisplay() {
        guard let rawIndex = currentRawIndex, rawIndex >= 0 && rawIndex < allItems.count else { return }
        if multiUpMode != .single {
            for s in 0..<displayedMultiUpPositions.count {
                let pos = displayedMultiUpPositions[s]
                guard pos < filteredIndices.count else { continue }
                let raw = filteredIndices[pos]
                let itm = allItems[raw]
                let m = cullingData[itm.id] ?? CullingMetadata()
                let burstInfo = burstClusterCache[pos] ?? nil
                let isSlotHero = burstInfo?.isHero ?? false
                let burstDesc: String?
                if isSlotHero {
                    burstDesc = "👑 BEST IN BURST"
                } else if let b = burstInfo {
                    burstDesc = "📸 BURST [\(b.indexInBurst)/\(b.totalInBurst)]"
                } else {
                    burstDesc = nil
                }
                let slotScore = AestheticsEngine.shared.cachedScore(for: itm.url.path)
                let sInfo = SplitPaneInfo(
                    slot: s + 1,
                    filename: itm.displayName,
                    pick: m.pick,
                    rating: m.rating,
                    color: m.color,
                    isPairScouting: true,
                    aestheticScore: slotScore,
                    burstDescription: burstDesc,
                    isHero: isSlotHero
                )
                slideView.updateSplitPaneInfo(slot: s + 1, info: sInfo)
            }
            for s in displayedMultiUpPositions.count..<4 {
                slideView.updateSplitPaneInfo(slot: s + 1, info: nil)
            }
        }

        let primaryIdx = min(activeHoverSlot - 1, max(0, displayedMultiUpPositions.count - 1))
        guard let item = cachedSlotItems[primaryIdx] ?? cachedSlotItems[0] ?? (rawIndex < allItems.count ? allItems[rawIndex] : nil) else { return }
        let decoded = cachedSlotDecoded[primaryIdx] ?? cachedSlotDecoded[0]

        let meta = cullingData[item.id] ?? CullingMetadata()
        let formattedSize = item.totalStackSize > 0
            ? ByteCountFormatter.string(fromByteCount: item.totalStackSize, countStyle: .file)
            : nil
        let resText = (decoded != nil) ? "\(decoded!.originalWidth) × \(decoded!.originalHeight)" : nil
        let filterBadge = currentFilter == .all ? nil : currentFilter.title

        var hudMeta = meta
        if multiUpMode != .single {
            hudMeta.cameraProfile = .asShot
        }

        let cachedAesthetic = AestheticsEngine.shared.cachedScore(for: item.url.path)

        let primaryPos = (primaryIdx < displayedMultiUpPositions.count) ? displayedMultiUpPositions[primaryIdx] : currentFilteredPos
        var burstBreadcrumb: BurstBreadcrumbInfo? = nil
        if let cached = burstClusterCache[primaryPos] {
            burstBreadcrumb = cached
        } else {
            burstClusterTask?.cancel()
            burstClusterTask = Task { @MainActor [weak self] in
                guard let self = self else { return }
                let result = await self.computeBurstCluster(for: primaryPos)
                let activePos = (self.activeHoverSlot <= self.displayedMultiUpPositions.count)
                    ? self.displayedMultiUpPositions[self.activeHoverSlot - 1]
                    : self.currentFilteredPos
                if activePos == primaryPos {
                    self.slideView.updateBurstBreadcrumb(result)
                }
                if self.multiUpMode != .single {
                    for s in 0..<self.displayedMultiUpPositions.count {
                        let p = self.displayedMultiUpPositions[s]
                        if p < self.filteredIndices.count, let b = self.burstClusterCache[p] as? BurstBreadcrumbInfo {
                            let desc = b.isHero ? "👑 BEST IN BURST" : "📸 BURST [\(b.indexInBurst)/\(b.totalInBurst)]"
                            self.slideView.updateSlotScene(slot: s + 1, description: desc, isHero: b.isHero)
                        }
                    }
                }
            }
        }

        let info = HudInfo(
            currentIndex: currentFilteredPos,
            totalCount: filteredIndices.count,
            filename: item.displayName,
            dimensions: resText,
            fileSize: formattedSize,
            isRaw: (decoded?.isRaw == true) || item.rawURL != nil,
            isStacked: item.isStacked,
            isDownscaled: decoded?.isDownscaled ?? false,
            culling: hudMeta,
            autoAdvance: autoAdvance,
            filterTitle: filterBadge,
            isZoomed: slideView.isZoomed,
            exif: decoded?.exif,
            isSlideshow: isSlideshowActive,
            slideshowInterval: slideshowInterval,
            exportProgressText: exportProgressText,
            aestheticScore: cachedAesthetic,
            burstInfo: burstBreadcrumb
        )
        slideView.hudView.update(with: info)
    }

    public func slideViewHoverPaneChanged(to slot: Int) {
        guard multiUpMode != .single else { return }
        guard slot >= 1, slot <= displayedMultiUpPositions.count else { return }
        guard activeHoverSlot != slot else { return }
        activeHoverSlot = slot
        updateCullingDisplay()
        if isFaceOverlayVisible {
            refreshFaceOverlay()
        }

        if isHistogramVisible {
            let data = paneHistogramData[slot] ?? .empty
            slideView.updateHistogram(data, slot: slot)
        }

        if isExifVisible, let exifData = paneExifData[slot] {
            slideView.exifHud.update(with: exifData.exif, dimensions: exifData.dims, fileSize: exifData.size)
        }
    }

    private func updateHistogramAsync(for images: [CGImage?]) {
        let hoverSlot = activeHoverSlot
        let mode = multiUpMode
        Task.detached(priority: .userInitiated) { [weak self] in
            var results: [Int: HistogramData] = [:]
            for (i, img) in images.enumerated() {
                if let img = img {
                    results[i + 1] = HistogramEngine.compute(for: img)
                }
            }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.paneHistogramData = results
                if mode != .single {
                    let activeData = results[hoverSlot] ?? results[1] ?? .empty
                    self.slideView.updateHistogram(activeData, slot: hoverSlot)
                } else {
                    let singleData = results[1] ?? .empty
                    self.slideView.updateHistogram(singleData, slot: nil)
                }
            }
        }
    }

    private func updateClippingMaskAsync(for images: [CGImage?]) {
        let expectedIndex = currentRawIndex
        Task.detached(priority: .userInitiated) { [weak self] in
            var masks: [CGImage?] = Array(repeating: nil, count: 4)
            for (i, img) in images.enumerated() where i < 4 {
                if let img = img {
                    masks[i] = ClippingEngine.generateClippingMask(for: img)
                }
            }
            Task { @MainActor [weak self] in
                guard let self = self, self.currentRawIndex == expectedIndex else { return }
                self.slideView.updateClippingMasks(masks)
            }
        }
    }

    private func updatePeakingMaskAsync(for images: [CGImage?]) {
        let expectedIndex = currentRawIndex
        Task.detached(priority: .userInitiated) { [weak self] in
            var masks: [CGImage?] = Array(repeating: nil, count: 4)
            for (i, img) in images.enumerated() where i < 4 {
                if let img = img {
                    masks[i] = FocusPeakingEngine.generatePeakingMask(for: img)
                }
            }
            Task { @MainActor [weak self] in
                guard let self = self, self.currentRawIndex == expectedIndex else { return }
                self.slideView.updatePeakingMasks(masks)
            }
        }
    }

    // MARK: - Camera Profiles & Picture Controls

    public func slideViewCycleCameraProfile() {
        // Enforce unbiased neutral standard baseline in multi-up compare
        if multiUpMode != .single {
            slideView.showToast("Profiles Locked in Multi-Up", icon: "🎨", shortcut: "V")
            return
        }

        guard let rawIndex = currentRawIndex else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        let item = allItems[rawIndex]
        var meta = cullingData[item.id] ?? CullingMetadata()
        let previous = meta.cameraProfile

        let allProfiles = CameraProfile.allCases
        let currentIdx = allProfiles.firstIndex(of: meta.cameraProfile ?? .asShot) ?? 0
        let nextIdx = (currentIdx + 1) % allProfiles.count
        let nextProfile = allProfiles[nextIdx]

        meta.cameraProfile = nextProfile
        cullingData[item.id] = meta

        cullingUndoManager.record(.profile(itemID: item.id, rawIndex: rawIndex, previous: previous, new: nextProfile))

        saveMetadataAsync(meta: meta, for: item)

        Task {
            let brand = CameraProfileEngine.detectBrand(for: item, exif: nil)
            let brandName = nextProfile.displayName(for: brand)
            await loadAndDisplayCurrent()
            slideView.showToast("Profile: \(brandName)", icon: "🎨", shortcut: "V")
        }
    }

    // MARK: - Independent Multi-Up Culling Actions

    public func slideViewSetRating(_ rating: Int) {
        let targetPos = (multiUpMode != .single && activeHoverSlot <= displayedMultiUpPositions.count) ? displayedMultiUpPositions[activeHoverSlot - 1] : currentFilteredPos
        guard targetPos < filteredIndices.count else { return }
        let targetRawIndex = filteredIndices[targetPos]

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let item = allItems[targetRawIndex]
        var meta = cullingData[item.id] ?? CullingMetadata()
        let previous = meta.rating
        let newRating = (meta.rating == rating) ? 0 : rating
        meta.rating = newRating
        cullingData[item.id] = meta

        cullingUndoManager.record(.rating(itemID: item.id, rawIndex: targetRawIndex, previous: previous, new: newRating))

        if currentFilter != .all && !currentFilter.matches(meta: meta) {
            applyCullingUpdate()
        } else {
            updateCullingDisplay()
            if autoAdvance && multiUpMode == .single {
                slideViewRequestNext()
            }
        }
        saveMetadataAsync(meta: meta, for: item)
    }

    public func slideViewSetPick(_ pick: PickStatus) {
        let targetPos = (multiUpMode != .single && activeHoverSlot <= displayedMultiUpPositions.count) ? displayedMultiUpPositions[activeHoverSlot - 1] : currentFilteredPos
        guard targetPos < filteredIndices.count else { return }
        let targetRawIndex = filteredIndices[targetPos]

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let item = allItems[targetRawIndex]
        var meta = cullingData[item.id] ?? CullingMetadata()
        let previous = meta.pick
        let newPick = (meta.pick == pick) ? .unflagged : pick
        meta.pick = newPick
        cullingData[item.id] = meta

        cullingUndoManager.record(.pick(itemID: item.id, rawIndex: targetRawIndex, previous: previous, new: newPick))

        if currentFilter != .all && !currentFilter.matches(meta: meta) {
            applyCullingUpdate()
        } else {
            updateCullingDisplay()
            if autoAdvance && multiUpMode == .single {
                slideViewRequestNext()
            }
        }
        saveMetadataAsync(meta: meta, for: item)
    }

    public func slideViewPickWinner(slot: Int) {
        // King of the Hill elimination removed; no-op preserved for protocol compatibility
    }

    /// Proposal 4: Burst Knockout Culling (⇧P)
    /// Flags the winner frame as Pick, automatically marks all other frames in the burst as Reject,
    /// groups into a compound undo step, and leaps seamlessly to the start of the next scene.
    public func slideViewBurstKnockout() {
        stopSlideshowIfRunning()
        guard !filteredIndices.isEmpty else { return }

        let winnerPos = (multiUpMode != .single && activeHoverSlot <= displayedMultiUpPositions.count)
            ? displayedMultiUpPositions[activeHoverSlot - 1]
            : currentFilteredPos
        guard winnerPos >= 0, winnerPos < filteredIndices.count else { return }

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            let burst: BurstBreadcrumbInfo?
            if let cached = self.burstClusterCache[winnerPos] {
                burst = cached
            } else {
                burst = await self.computeBurstCluster(for: winnerPos)
            }

            guard let b = burst, b.totalInBurst > 1 else {
                self.slideViewSetPick(.pick)
                self.slideView.showToast("✓ Picked (Single Photo)", icon: "✓", shortcut: "⇧P", tint: .systemGreen)
                return
            }

            let clusterStart = winnerPos - (b.indexInBurst - 1)
            let clusterEnd = clusterStart + b.totalInBurst - 1
            guard clusterStart >= 0, clusterEnd < self.filteredIndices.count else { return }

            var compoundActions: [CullingAction] = []

            // Winner photo
            let rawWinner = self.filteredIndices[winnerPos]
            let itemWinner = self.allItems[rawWinner]
            var metaWinner = self.cullingData[itemWinner.id] ?? CullingMetadata()
            let prevWinnerPick = metaWinner.pick
            if prevWinnerPick != .pick {
                compoundActions.append(.pick(itemID: itemWinner.id, rawIndex: rawWinner, previous: prevWinnerPick, new: .pick))
                metaWinner.pick = .pick
                self.cullingData[itemWinner.id] = metaWinner
                self.saveMetadataAsync(meta: metaWinner, for: itemWinner)
            }

            // Reject all siblings in the burst
            var rejectedCount = 0
            for p in clusterStart...clusterEnd {
                guard p != winnerPos, p < self.filteredIndices.count else { continue }
                let rawSibling = self.filteredIndices[p]
                let itemSibling = self.allItems[rawSibling]
                var metaSibling = self.cullingData[itemSibling.id] ?? CullingMetadata()
                let prevSiblingPick = metaSibling.pick
                if prevSiblingPick != .reject {
                    compoundActions.append(.pick(itemID: itemSibling.id, rawIndex: rawSibling, previous: prevSiblingPick, new: .reject))
                    metaSibling.pick = .reject
                    self.cullingData[itemSibling.id] = metaSibling
                    self.saveMetadataAsync(meta: metaSibling, for: itemSibling)
                }
                rejectedCount += 1
            }

            if !compoundActions.isEmpty {
                self.cullingUndoManager.record(.compound(compoundActions))
            }

            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            self.slideView.showToast("✓ Picked #\(b.indexInBurst) • Rejected \(rejectedCount) in burst", icon: "⚡", shortcut: "⇧P", tint: .systemGreen)

            self.updateCullingDisplay()

            // Auto-advance directly to the next scene
            self.slideViewRequestNextScene()
        }
    }

    public func slideViewSetColor(_ color: ColorLabel) {
        let targetPos = (multiUpMode != .single && activeHoverSlot <= displayedMultiUpPositions.count) ? displayedMultiUpPositions[activeHoverSlot - 1] : currentFilteredPos
        guard targetPos < filteredIndices.count else { return }
        let targetRawIndex = filteredIndices[targetPos]

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let item = allItems[targetRawIndex]
        var meta = cullingData[item.id] ?? CullingMetadata()
        let previous = meta.color
        let newColor = (meta.color == color) ? .none : color
        meta.color = newColor
        cullingData[item.id] = meta

        cullingUndoManager.record(.color(itemID: item.id, rawIndex: targetRawIndex, previous: previous, new: newColor))

        if currentFilter != .all && !currentFilter.matches(meta: meta) {
            applyCullingUpdate()
        } else {
            updateCullingDisplay()
            if autoAdvance && multiUpMode == .single {
                slideViewRequestNext()
            }
        }
        saveMetadataAsync(meta: meta, for: item)
    }

    private func saveMetadataAsync(meta: CullingMetadata, for item: SlideItem) {
        Task.detached(priority: .utility) {
            do {
                let targetURL = item.rawURL ?? item.url
                try XmpSidecarManager.save(metadata: meta, for: targetURL)
            } catch {
                NSLog("Glance: Failed to save XMP sidecar for \(item.filename): \(error)")
            }
        }
    }

    private func applyCullingUpdate() {
        Task {
            if currentFilter != .all {
                let prevRaw = currentRawIndex
                rebuildFilter(targetIndex: prevRaw)
            }

            await loadAndDisplayCurrent()

            if autoAdvance && multiUpMode == .single {
                slideViewRequestNext()
            }
        }
    }

    public func slideViewToggleAutoAdvance() {
        autoAdvance.toggle()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        slideView.showToast(autoAdvance ? "Auto-Advance: ON" : "Auto-Advance: OFF", icon: "⚡", shortcut: "C")
        Task {
            await loadAndDisplayCurrent()
        }
    }

    public func slideViewCycleFilter() {
        filterBeforeMultiUp = nil
        switch currentFilter {
        case .all:
            currentFilter = .hideRejects
        case .hideRejects:
            currentFilter = .picksOnly
        case .picksOnly:
            currentFilter = .rejectsOnly
        case .rejectsOnly:
            currentFilter = .unratedOnly
        case .unratedOnly:
            currentFilter = .minRating(3)
        case .minRating(3):
            currentFilter = .minRating(5)
        case .minRating:
            currentFilter = .all
        }

        rebuildFilter()
        slideView.showToast("Filter: \(currentFilter.title)", icon: "🔍", shortcut: "\\")
        Task {
            await loadAndDisplayCurrent()
        }
    }

    public func slideViewCycleMultiUp() {
        let newMode = multiUpMode.next
        multiUpMode = newMode
        slideView.setMultiUpMode(newMode)

        if newMode == .twoUp {
            activeHoverSlot = 1
            if currentFilter == .all || currentFilter == .rejectsOnly {
                filterBeforeMultiUp = currentFilter
                currentFilter = .hideRejects
                rebuildFilter(targetIndex: currentRawIndex)
            }
            slideView.showToast("2-UP Compare (Pairs)", icon: "⊞", shortcut: "S")
        } else if newMode == .fourUp {
            activeHoverSlot = 1
            slideView.showToast("4-UP Quad Compare", icon: "⊞", shortcut: "S")
        } else {
            activeHoverSlot = 1
            if let prev = filterBeforeMultiUp {
                currentFilter = prev
                filterBeforeMultiUp = nil
                rebuildFilter(targetIndex: currentRawIndex)
            }
            slideView.showToast("Single Fullscreen", icon: "⊞", shortcut: "S")
            if isHistogramVisible {
                slideView.updateHistogram(paneHistogramData[1] ?? .empty, slot: nil)
            }
        }
        Task {
            await loadAndDisplayCurrent()
        }
    }

    public func slideViewToggleSplitCompare() {
        slideViewCycleMultiUp()
    }

    public func slideViewToggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    public func slideViewClose() {
        stopSlideshowTimer()
        NSApp.terminate(nil)
    }

    public func slideViewDidDrop(url: URL) {
        open(targetURL: url, startFullScreen: false)
    }

    // MARK: - Phase 4: Output & Workflow Productivity

    public func slideViewStopSlideshow() {
        stopSlideshowIfRunning()
    }

    private func stopSlideshowIfRunning() {
        guard isSlideshowActive else { return }
        isSlideshowActive = false
        stopSlideshowTimer()
        slideView.hudView.updateSlideshowState(isActive: false, interval: slideshowInterval)
    }

    public func slideViewToggleSlideshow() {
        isSlideshowActive.toggle()
        if isSlideshowActive {
            startSlideshowTimer()
            slideView.hudView.updateSlideshowState(isActive: true, interval: slideshowInterval)
        } else {
            stopSlideshowTimer()
            slideView.hudView.updateSlideshowState(isActive: false, interval: slideshowInterval)
        }
    }

    public func slideViewAdjustSlideshowInterval(increase: Bool) {
        guard isSlideshowActive else { return }

        let steps: [Double] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 10.0, 12.0, 15.0, 20.0, 30.0]

        if increase {
            if let next = steps.first(where: { $0 > slideshowInterval }) {
                slideshowInterval = next
            }
        } else {
            if let prev = steps.last(where: { $0 < slideshowInterval }) {
                slideshowInterval = prev
            }
        }

        startSlideshowTimer()
        slideView.hudView.updateSlideshowState(isActive: true, interval: slideshowInterval)
    }

    private func startSlideshowTimer() {
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: slideshowInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceSlideshow()
            }
        }
    }

    private func advanceSlideshow() {
        guard isSlideshowActive, !filteredIndices.isEmpty else { return }
        if currentFilteredPos + 1 < filteredIndices.count {
            navigate(toFilteredPos: currentFilteredPos + 1, direction: .forward)
        } else {
            navigate(toFilteredPos: 0, direction: .forward)
        }
    }

    private func stopSlideshowTimer() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }

    public func slideViewRotate(direction: RotationDirection) {
        stopSlideshowIfRunning()
        guard let rawIndex = currentRawIndex, rawIndex >= 0 && rawIndex < allItems.count else { return }

        // In multi-up mode, rotate all currently displayed photos concurrently
        if multiUpMode != .single {
            var itemsToRotate: [(SlideItem, Int)] = []
            for s in 0..<displayedMultiUpPositions.count {
                let pos = displayedMultiUpPositions[s]
                if pos < filteredIndices.count {
                    let rIdx = filteredIndices[pos]
                    itemsToRotate.append((allItems[rIdx], rIdx))
                }
            }

            let actions: [CullingAction] = itemsToRotate.map {
                .rotate(itemID: $0.0.id, rawIndex: $0.1, direction: direction)
            }
            cullingUndoManager.record(.compound(actions))
            slideView.showToast("Rotating Burst...", icon: "🔄", shortcut: "R")

            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    for (item, rIdx) in itemsToRotate {
                        _ = try LosslessRotationEngine.rotate(item: item, direction: direction)
                        await self?.pipeline.invalidateCache(at: rIdx)
                    }
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let dirTitle = (direction == .clockwise) ? "Clockwise 90° [R]" : "Counter-Clockwise 90° [L]"
                        self.slideView.showToast("Rotated Burst \(dirTitle)", icon: "🔄", shortcut: "R")
                        await self.loadAndDisplayCurrent()
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        self?.slideView.showToast("Rotation Failed", icon: "⚠️")
                    }
                }
            }
            return
        }

        let item = allItems[rawIndex]
        cullingUndoManager.record(.rotate(itemID: item.id, rawIndex: rawIndex, direction: direction))
        slideView.showToast("Rotating...", icon: "🔄", shortcut: "R")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try LosslessRotationEngine.rotate(item: item, direction: direction)
                await self?.pipeline.invalidateCache(at: rawIndex)
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let dirTitle = (direction == .clockwise) ? "Clockwise 90° [R]" : "Counter-Clockwise 90° [L]"
                    self.slideView.showToast("Rotated \(dirTitle)", icon: "🔄", shortcut: "R")
                    await self.loadAndDisplayCurrent()
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.slideView.showToast("Rotation Failed", icon: "⚠️")
                }
            }
        }
    }

    /// Batch Exports all flagged ✓ Picks to `./Selects` directory
    public func slideViewRequestBatchExportPicks() {
        stopSlideshowIfRunning()
        guard !allItems.isEmpty, !isExporting else { return }

        let picks = allItems.filter { item in
            let meta = cullingData[item.id] ?? CullingMetadata()
            return meta.pick == .pick
        }

        guard !picks.isEmpty else {
            slideView.showToast("No Picks Flagged • Flag keepers with [P]", icon: "📁", shortcut: "⇧E", tint: .systemOrange)
            return
        }

        guard let firstItem = allItems.first else { return }
        let parentDir = firstItem.url.deletingLastPathComponent()
        let destination = parentDir.appendingPathComponent("Selects")

        isExporting = true
        slideView.showToast("Batch Exporting \(picks.count) Picks to ./Selects...", icon: "📁", shortcut: "⇧E", tint: .systemCyan)

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let summary = try await ExportManager.shared.export(
                    items: picks,
                    destinationDirectory: destination
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.slideView.showToast("Exporting \(progress.current) / \(progress.total) Picks...", icon: "📁", shortcut: "⇧E")
                    }
                }

                self.isExporting = false
                let finishMsg = "✓ Exported \(summary.exportedCount) Picks (\(summary.totalFilesWritten) files) to ./Selects"
                self.slideView.showToast(finishMsg, icon: "📁", shortcut: "⇧E", tint: .systemGreen)
                NSSound(named: "Glass")?.play()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                self.isExporting = false
                self.slideView.showToast("Export Failed", icon: "⚠️", tint: .systemRed)
            }
        }
    }

    /// Quick toggle between Picks Only filter and All Files
    public func slideViewTogglePicksFilter() {
        stopSlideshowIfRunning()
        if currentFilter == .picksOnly {
            currentFilter = filterBeforePicksToggle ?? .all
            filterBeforePicksToggle = nil
            slideView.showToast("Filter: \(currentFilter.title)", icon: "🔍", shortcut: "⇧\\")
        } else {
            filterBeforePicksToggle = currentFilter
            currentFilter = .picksOnly
            slideView.showToast("Filter: Picks Only (✓)", icon: "✓", shortcut: "⇧\\", tint: .systemGreen)
        }
        rebuildFilter(targetIndex: currentRawIndex)
        Task {
            await loadAndDisplayCurrent()
        }
    }

    public func slideViewRequestExport() {
        stopSlideshowIfRunning()
        guard !allItems.isEmpty, !isExporting else { return }

        let itemsToExport: [SlideItem]
        let reason: String
        if currentFilter != .all {
            itemsToExport = filteredIndices.map { allItems[$0] }
            reason = "\(currentFilter.title) (\(itemsToExport.count) shots)"
        } else {
            let picks = allItems.filter { item in
                let meta = cullingData[item.id] ?? CullingMetadata()
                return meta.pick == .pick || meta.rating >= 4
            }
            if !picks.isEmpty {
                itemsToExport = picks
                reason = "Picks & 4★+ (\(itemsToExport.count) shots)"
            } else if let raw = currentRawIndex, raw < allItems.count {
                itemsToExport = [allItems[raw]]
                reason = "Current Shot"
            } else {
                itemsToExport = allItems
                reason = "All Files (\(itemsToExport.count) shots)"
            }
        }

        guard !itemsToExport.isEmpty else {
            slideView.showToast("No Photos to Export", icon: "📁", shortcut: "E")
            return
        }

        guard let firstItem = allItems.first else { return }
        let parentDir = firstItem.url.deletingLastPathComponent()
        let destination = parentDir.appendingPathComponent("Picks")

        isExporting = true
        slideView.showToast("Exporting \(reason)...", icon: "📁", shortcut: "E")

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let summary = try await ExportManager.shared.export(
                    items: itemsToExport,
                    destinationDirectory: destination
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.slideView.showToast("Exporting \(progress.current) / \(progress.total)...", icon: "📁", shortcut: "E")
                    }
                }

                self.isExporting = false
                let finishMsg = "Exported \(summary.exportedCount) shots (\(summary.totalFilesWritten) files) to ./Picks"
                self.slideView.showToast(finishMsg, icon: "📁", shortcut: "E", tint: .systemGreen)
                NSSound(named: "Glass")?.play()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                self.isExporting = false
                self.slideView.showToast("Export Failed", icon: "⚠️", tint: .systemRed)
            }
        }
    }

    // MARK: - Window Delegate

    public func windowDidResize(_ notification: Notification) {
        guard let window = self.window else { return }
        let scale = window.backingScaleFactor
        let maxPixelSize = Int(max(window.frame.width, window.frame.height) * scale)
        Task {
            await pipeline.updateBoundingSize(maxPixelSize)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        directoryWatcher?.stop()
        NSApp.terminate(nil)
    }
}

// MARK: - DirectoryWatcherDelegate

extension FullScreenWindowController: DirectoryWatcherDelegate {
    public func directoryWatcherDidDetectChanges(in directoryURL: URL) {
        Task { [weak self] in
            guard let self = self else { return }

            let currentURL: URL? = self.currentRawIndex.flatMap {
                $0 < self.allItems.count ? self.allItems[$0].url : nil
            }

            guard let scanResult = try? await self.scanner.scan(targetURL: directoryURL) else { return }
            guard !scanResult.items.isEmpty else { return }

            self.allItems = scanResult.items

            let targetIdx = currentURL.flatMap { cur in
                self.allItems.firstIndex(where: { $0.url == cur || $0.allURLs.contains(cur) })
            } ?? 0

            self.rebuildFilter(targetIndex: targetIdx)
            await self.pipeline.setPlaylist(
                items: self.allItems,
                initialIndex: targetIdx,
                maxPixelSize: self.pipelineMaxPixelSize
            )
        }
    }

    // MARK: - Multi-Level Undo & Redo

    public func slideViewRequestUndo() {
        stopSlideshowIfRunning()
        guard let action = cullingUndoManager.popUndo() else {
            slideView.showToast("Nothing to Undo", icon: "↩", shortcut: "⌘Z")
            return
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        switch action {
        case .compound(let actions):
            for act in actions.reversed() {
                applyUndoSingleAction(act)
            }
            slideView.showToast("Undone", icon: "↩", shortcut: "⌘Z")
            Task {
                for act in actions {
                    if case .rotate(_, let rawIndex, _) = act {
                        await pipeline.invalidateCache(at: rawIndex)
                    }
                }
                rebuildFilter(targetIndex: currentRawIndex)
                await loadAndDisplayCurrent()
            }
            return
        case .rating(let itemID, _, let previous, _):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.rating = previous
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)


        case .pick(let itemID, _, let previous, _):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.pick = previous
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)


        case .color(let itemID, _, let previous, _):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.color = previous
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)


        case .profile(let itemID, _, let previous, _):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.cameraProfile = previous
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)
            let brand = CameraProfileEngine.detectBrand(for: item, exif: nil)
            let profName = previous?.displayName(for: brand) ?? "As Shot"
            slideView.showToast("Undone Profile: \(profName)", icon: "↩", shortcut: "⌘Z")

        case .rotate(let itemID, _, let direction):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            let reverseDir: RotationDirection = (direction == .clockwise) ? .counterClockwise : .clockwise
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = try? LosslessRotationEngine.rotate(item: item, direction: reverseDir)
                await self?.pipeline.invalidateCache(at: idx)
                Task { @MainActor [weak self] in
                    self?.jumpToRawIndex(idx)
                    self?.slideView.showToast("Undone Rotation", icon: "↩", shortcut: "⌘Z")
                }
            }

        case .delete(let item, let rawIndex, let previousMeta, let trashedRecords):
            Task {
                for rec in trashedRecords {
                    try? await TrashManager.restore(record: rec)
                }
                let insertIdx = min(rawIndex, self.allItems.count)
                self.allItems.insert(item, at: insertIdx)
                if let pMeta = previousMeta {
                    self.cullingData[item.id] = pMeta
                }
                _ = await self.pipeline.insertItem(item, at: insertIdx)
                self.rebuildFilter()
                if let fPos = self.filteredIndices.firstIndex(of: insertIdx) {
                    self.currentFilteredPos = fPos
                }
                await self.loadAndDisplayCurrent()
                self.slideView.showToast("Restored: \(item.displayName)", icon: "↩", shortcut: "⌘Z")
            }
        }
    }

    public func slideViewRequestRedo() {
        stopSlideshowIfRunning()
        guard let action = cullingUndoManager.popRedo() else {
            slideView.showToast("Nothing to Redo", icon: "↪", shortcut: "⇧⌘Z")
            return
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        switch action {
        case .compound(let actions):
            for act in actions {
                applyRedoSingleAction(act)
            }
            slideView.showToast("Redone", icon: "↪", shortcut: "⇧⌘Z")
            Task {
                for act in actions {
                    if case .rotate(_, let rawIndex, _) = act {
                        await pipeline.invalidateCache(at: rawIndex)
                    }
                }
                rebuildFilter(targetIndex: currentRawIndex)
                await loadAndDisplayCurrent()
            }
            return
        case .rating(let itemID, _, _, let new):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.rating = new
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)


        case .pick(let itemID, _, _, let new):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.pick = new
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)


        case .color(let itemID, _, _, let new):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.color = new
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)


        case .profile(let itemID, _, _, let new):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.cameraProfile = new
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)
            let brand = CameraProfileEngine.detectBrand(for: item, exif: nil)
            let profName = new?.displayName(for: brand) ?? "As Shot"
            slideView.showToast("Redone Profile: \(profName)", icon: "↪", shortcut: "⇧⌘Z")

        case .rotate(let itemID, _, let direction):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = try? LosslessRotationEngine.rotate(item: item, direction: direction)
                await self?.pipeline.invalidateCache(at: idx)
                Task { @MainActor [weak self] in
                    self?.jumpToRawIndex(idx)
                    self?.slideView.showToast("Redone Rotation", icon: "↪", shortcut: "⇧⌘Z")
                }
            }

        case .delete(let item, _, _, let trashedRecords):
            Task {
                guard let idx = self.allItems.firstIndex(where: { $0.id == item.id }) else { return }
                for rec in trashedRecords {
                    _ = try? await TrashManager.moveToTrash(url: rec.originalURL)
                }
                _ = await self.pipeline.removeItem(at: idx)
                self.allItems.remove(at: idx)
                self.cullingData.removeValue(forKey: item.id)
                self.rebuildFilter()
                if self.allItems.isEmpty {
                    self.displayEmptyState("Directory is now empty.")
                } else {
                    await self.loadAndDisplayCurrent()
                }
                self.slideView.showToast("Trashed Again", icon: "↪", shortcut: "⇧⌘Z")
            }
        }
    }

    private func jumpToRawIndex(_ rawIndex: Int) {
        rebuildFilter()
        if let fPos = filteredIndices.firstIndex(of: rawIndex) {
            currentFilteredPos = fPos
        }
        Task {
            await loadAndDisplayCurrent()
        }
    }

    // MARK: - External App Handoff

    public func slideViewRequestOpenInEditor() {
        stopSlideshowIfRunning()
        guard let rawIndex = currentRawIndex else { return }
        let item = allItems[rawIndex]
        let targetURL = item.rawURL ?? item.url

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        NSWorkspace.shared.open(targetURL)
        slideView.showToast("Opening: \(targetURL.lastPathComponent)", icon: "📂")
    }

    private func applyUndoSingleAction(_ action: CullingAction) {
        switch action {
        case .compound(let actions):
            for act in actions.reversed() { applyUndoSingleAction(act) }
        case .rating(let itemID, _, let previous, _):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.rating = previous
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: allItems[idx])
        case .pick(let itemID, _, let previous, _):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.pick = previous
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: allItems[idx])
        case .color(let itemID, _, let previous, _):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.color = previous
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: allItems[idx])
        case .profile(let itemID, _, let previous, _):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.cameraProfile = previous
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: allItems[idx])
        case .rotate(let itemID, _, let direction):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            let reverseDir: RotationDirection = (direction == .clockwise) ? .counterClockwise : .clockwise
            _ = try? LosslessRotationEngine.rotate(item: item, direction: reverseDir)
        case .delete:
            break
        }
    }

    private func applyRedoSingleAction(_ action: CullingAction) {
        switch action {
        case .compound(let actions):
            for act in actions { applyRedoSingleAction(act) }
        case .rating(let itemID, _, _, let new):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.rating = new
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: allItems[idx])
        case .pick(let itemID, _, _, let new):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.pick = new
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: allItems[idx])
        case .color(let itemID, _, _, let new):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.color = new
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: allItems[idx])
        case .profile(let itemID, _, _, let new):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.cameraProfile = new
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: allItems[idx])
        case .rotate(let itemID, _, let direction):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            _ = try? LosslessRotationEngine.rotate(item: item, direction: direction)
        case .delete:
            break
        }
    }
}
