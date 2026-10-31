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
    private var filterBeforeMultiUp: CullingFilter? = nil

    // Phase 3: Histogram & Clipping Warnings
    private var isHistogramVisible: Bool = false
    private var isClippingVisible: Bool = false
    private var isFocusPeakingVisible: Bool = false
    private var isExifVisible: Bool = false
    private var paneHistogramData: [Int: HistogramData] = [:]
    private var paneExifData: [Int: (exif: ExifMetadata?, dims: String, size: String?)] = [:]

    // Phase 4: Output & Productivity
    private var isSlideshowActive: Bool = false
    private var slideshowInterval: Double = 3.0
    private var slideshowTimer: Timer? = nil

    // Auto Face & Eye Focus Jump
    private var detectedFacesForCurrentSlide: [DetectedFace] = []
    private var detectedFacesForChallengerSlide: [DetectedFace] = []
    private var currentFaceIndex: Int = 0

    // Multi-Level Undo & Redo
    private let cullingUndoManager = CullingUndoManager.shared

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
        var slotImages: [CGImage?] = Array(repeating: nil, count: 4)
        var slotSizes: [CGSize] = Array(repeating: .zero, count: 4)
        var slotInfos: [SplitPaneInfo?] = Array(repeating: nil, count: 4)
        var slotDecoded: [DecodedImage?] = Array(repeating: nil, count: 4)
        var slotItems: [SlideItem?] = Array(repeating: nil, count: 4)
        var slotPaths: [String?] = Array(repeating: nil, count: 4)

        for s in 0..<slotCount {
            let pos = currentFilteredPos + s
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
                slotInfos[s] = SplitPaneInfo(
                    slot: s + 1,
                    filename: itm.displayName,
                    pick: m.pick,
                    rating: m.rating,
                    color: m.color,
                    isPairScouting: true
                )
            }
        }

        // Primary item under view / active slot
        let primaryIdx = min(activeHoverSlot - 1, slotCount - 1)
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

        let cachedAesthetic = (multiUpMode != .single) ? nil : AestheticsEngine.shared.cachedScore(for: item.url.path)

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
            aestheticScore: cachedAesthetic
        )

        slideView.displayMultiUp(
            images: slotImages,
            nativeSizes: slotSizes,
            splitInfos: slotInfos,
            info: info
        )

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

        // Face detection asynchronously
        currentFaceIndex = 0
        detectedFacesForCurrentSlide = []
        detectedFacesForChallengerSlide = []
        if let p = slotPaths[0], let img0 = slotImages[0] {
            Task.detached(priority: .utility) { [weak self] in
                let faces = await FaceDetectionEngine.shared.detectFaces(in: img0, cacheKey: p)
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentRawIndex == rawIndex else { return }
                    self.detectedFacesForCurrentSlide = faces
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

        let stride = multiUpMode.rawValue
        let nextPos = currentFilteredPos + stride

        if nextPos < filteredIndices.count {
            navigate(toFilteredPos: nextPos, direction: .forward)
        } else if currentFilteredPos + 1 < filteredIndices.count && multiUpMode != .single {
            // Remainder partial block at end of directory
            navigate(toFilteredPos: currentFilteredPos + 1, direction: .forward)
            slideView.hudView.showMessage("Last Photo in Set")
        } else {
            if multiUpMode == .single {
                navigate(toFilteredPos: 0, direction: .forward)
            } else {
                slideView.hudView.showMessage("End of Set")
            }
        }
    }

    public func slideViewRequestPrevious() {
        stopSlideshowIfRunning()
        guard !filteredIndices.isEmpty else { return }

        let stride = multiUpMode.rawValue
        let prevPos = currentFilteredPos - stride

        if prevPos >= 0 {
            navigate(toFilteredPos: prevPos, direction: .backward)
        } else if currentFilteredPos > 0 && multiUpMode != .single {
            navigate(toFilteredPos: 0, direction: .backward)
        } else {
            if multiUpMode == .single {
                navigate(toFilteredPos: filteredIndices.count - 1, direction: .backward)
            } else {
                slideView.hudView.showMessage("First photos in set")
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

    public func slideViewRequestDelete() {
        stopSlideshowIfRunning()
        let targetPos = (multiUpMode != .single) ? (currentFilteredPos + activeHoverSlot - 1) : currentFilteredPos
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
                self.slideView.hudView.showMessage("Moved to Trash [⌘Z to Undo]")
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
            slideView.hudView.showMessage("No rejected photos to purge.")
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
                self.slideView.hudView.showMessage("Purged \(trashedCount) rejected photos to Trash.")
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

            // Instantly zoom the view using the screen-bounded layer (0ms latency!)
            slideView.setZoom(true, anchorPointInView: mouseLocation)

            let slotCount = multiUpMode.rawValue
            var rawIndicesToFetch: [Int: Int] = [:] // [slot: rawIndex]
            for s in 0..<slotCount {
                let pos = currentFilteredPos + s
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

    // MARK: - Auto Face & Eye Focus Jump

    public func slideViewJumpToFaceEye() {
        stopSlideshowIfRunning()
        guard let rawIndex = currentRawIndex else { return }
        let item = allItems[rawIndex]

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        Task {
            var faces = self.detectedFacesForCurrentSlide
            if faces.isEmpty {
                if let decoded = try? await self.pipeline.getImage(at: rawIndex) {
                    faces = await FaceDetectionEngine.shared.detectFaces(in: decoded.image, cacheKey: item.url.path)
                    self.detectedFacesForCurrentSlide = faces
                }
            }

            guard !faces.isEmpty else {
                self.slideView.hudView.showMessage("No faces detected in frame")
                if !self.slideView.isZoomed {
                    let mouseInWindow = self.window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: self.slideView.bounds.midX, y: self.slideView.bounds.midY)
                    let localPt = self.slideView.convert(mouseInWindow, from: nil)
                    self.slideView.setZoom(true, anchorPointInView: localPt)
                }
                return
            }

            let leftFace = faces[self.currentFaceIndex % faces.count]
            self.currentFaceIndex += 1

            let label: String
            if faces.count > 1 {
                label = "👁️ Face \(((self.currentFaceIndex - 1) % faces.count) + 1)/\(faces.count) (Eye Focus)"
            } else {
                label = "👁️ Eye Focus"
            }

            let leftPoint = leftFace.eyeCenter
            self.slideView.zoomToNormalizedPoint(
                leftPoint,
                rightNormPoint: leftPoint,
                label: label
            )

            // Concurrently fetch full resolution sensor data
            if let fullDec = try? await self.pipeline.getFullResolutionImage(at: rawIndex) {
                let dims = CGSize(width: fullDec.originalWidth, height: fullDec.originalHeight)
                self.slideView.zoomToNormalizedPoint(
                    leftPoint,
                    rightNormPoint: leftPoint,
                    fullResImage: fullDec.image,
                    originalDimensions: dims
                )
            }
        }
    }

    // MARK: - Phase 3: Histogram & Exposure Clipping Controls

    public func slideViewToggleHistogram() {
        isHistogramVisible.toggle()
        slideView.setHistogramVisible(isHistogramVisible)
        let msg = isHistogramVisible ? "RGB Histogram: ON [H]" : "RGB Histogram: OFF [H]"
        slideView.hudView.showMessage(msg)

        if isHistogramVisible {
            Task {
                await loadAndDisplayCurrent()
            }
        }
    }

    public func slideViewToggleExif() {
        isExifVisible.toggle()
        slideView.setExifVisible(isExifVisible)
        let msg = isExifVisible ? "EXIF Info: ON [I]" : "EXIF Info: OFF [I]"
        slideView.hudView.showMessage(msg)
    }

    public func slideViewToggleClipping() {
        isClippingVisible.toggle()
        slideView.setClippingActive(isClippingVisible)
        let msg = isClippingVisible ? "Clipping Warnings: ON [O]" : "Clipping Warnings: OFF [O]"
        slideView.hudView.showMessage(msg)

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
        let msg = isFocusPeakingVisible ? "Focus Peaking: ON [⇧F]" : "Focus Peaking: OFF [⇧F]"
        slideView.hudView.showMessage(msg)

        if isFocusPeakingVisible {
            Task {
                await loadAndDisplayCurrent()
            }
        } else {
            slideView.updatePeakingMasks([nil, nil, nil, nil])
        }
    }

    public func slideViewHoverPaneChanged(to slot: Int) {
        guard multiUpMode != .single else { return }
        guard activeHoverSlot != slot else { return }
        activeHoverSlot = slot

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
            slideView.hudView.showMessage("Color Profiles locked to Standard in Multi-Up Compare")
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
            slideView.hudView.showMessage("Profile: \(brandName) [V]")
        }
    }

    // MARK: - Independent Multi-Up Culling Actions

    public func slideViewSetRating(_ rating: Int) {
        let targetPos = (multiUpMode != .single) ? (currentFilteredPos + activeHoverSlot - 1) : currentFilteredPos
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

        if multiUpMode != .single {
            let starText = newRating > 0 ? "★ \(newRating)" : "Cleared"
            slideView.hudView.showMessage("Slot [ \(activeHoverSlot) ] Rating: \(starText)")
            Task { await loadAndDisplayCurrent() }
        } else {
            applyCullingUpdate()
        }
        saveMetadataAsync(meta: meta, for: item)
    }

    public func slideViewSetPick(_ pick: PickStatus) {
        let targetPos = (multiUpMode != .single) ? (currentFilteredPos + activeHoverSlot - 1) : currentFilteredPos
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

        let msg: String
        switch newPick {
        case .pick: msg = (multiUpMode != .single) ? "✓ Picked [ \(activeHoverSlot) ]" : "✓ Picked [P]"
        case .reject: msg = (multiUpMode != .single) ? "✕ Rejected [ \(activeHoverSlot) ]" : "✕ Rejected [X]"
        case .unflagged: msg = (multiUpMode != .single) ? "Unflagged [ \(activeHoverSlot) ]" : "Unflagged [U]"
        }
        slideView.hudView.showMessage(msg)

        if currentFilter == .hideRejects && newPick == .reject {
            rebuildFilter(targetIndex: currentRawIndex)
        }
        Task { await loadAndDisplayCurrent() }
        saveMetadataAsync(meta: meta, for: item)
    }

    public func slideViewPickWinner(slot: Int) {
        // King of the Hill elimination removed; no-op preserved for protocol compatibility
    }

    public func slideViewSetColor(_ color: ColorLabel) {
        let targetPos = (multiUpMode != .single) ? (currentFilteredPos + activeHoverSlot - 1) : currentFilteredPos
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

        if multiUpMode != .single {
            slideView.hudView.showMessage("Slot [ \(activeHoverSlot) ] Color: \(newColor.title)")
            Task { await loadAndDisplayCurrent() }
        } else {
            applyCullingUpdate()
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
        let status = autoAdvance ? "Auto-Advance: ON [C]" : "Auto-Advance: OFF [C]"
        slideView.hudView.showMessage(status)
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
        slideView.hudView.showMessage("Filter: \(currentFilter.title) [ \\ ]")
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
            slideView.hudView.showMessage("2-UP Compare [S] • Stepping: Pairs (±2)")
        } else if newMode == .fourUp {
            activeHoverSlot = 1
            slideView.hudView.showMessage("4-UP Quad Compare [S] • Stepping: Quads (±4)")
        } else {
            activeHoverSlot = 1
            if let prev = filterBeforeMultiUp {
                currentFilter = prev
                filterBeforeMultiUp = nil
                rebuildFilter(targetIndex: currentRawIndex)
            }
            slideView.hudView.showMessage("Single Fullscreen [S] • Stepping: Single (±1)")
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
            for s in 0..<multiUpMode.rawValue {
                let pos = currentFilteredPos + s
                if pos < filteredIndices.count {
                    let rIdx = filteredIndices[pos]
                    itemsToRotate.append((allItems[rIdx], rIdx))
                }
            }

            let actions: [CullingAction] = itemsToRotate.map {
                .rotate(itemID: $0.0.id, rawIndex: $0.1, direction: direction)
            }
            cullingUndoManager.record(.compound(actions))
            slideView.hudView.showMessage("Rotating Burst...")

            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    for (item, rIdx) in itemsToRotate {
                        _ = try LosslessRotationEngine.rotate(item: item, direction: direction)
                        await self?.pipeline.invalidateCache(at: rIdx)
                    }
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let dirTitle = (direction == .clockwise) ? "Clockwise 90° [R]" : "Counter-Clockwise 90° [L]"
                        self.slideView.hudView.showMessage("Rotated Burst \(dirTitle)")
                        await self.loadAndDisplayCurrent()
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        self?.slideView.hudView.showMessage("Rotation failed: \(error.localizedDescription)")
                    }
                }
            }
            return
        }

        let item = allItems[rawIndex]
        cullingUndoManager.record(.rotate(itemID: item.id, rawIndex: rawIndex, direction: direction))
        slideView.hudView.showMessage("Rotating...")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try LosslessRotationEngine.rotate(item: item, direction: direction)
                await self?.pipeline.invalidateCache(at: rawIndex)
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let dirTitle = (direction == .clockwise) ? "Clockwise 90° [R]" : "Counter-Clockwise 90° [L]"
                    self.slideView.hudView.showMessage("Rotated \(dirTitle)")
                    await self.loadAndDisplayCurrent()
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.slideView.hudView.showMessage("Rotation failed: \(error.localizedDescription)")
                }
            }
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
            slideView.hudView.showMessage("No photos to export.")
            return
        }

        guard let firstItem = allItems.first else { return }
        let parentDir = firstItem.url.deletingLastPathComponent()
        let destination = parentDir.appendingPathComponent("Picks")

        isExporting = true
        slideView.hudView.showMessage("Exporting \(reason)...")

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let summary = try await ExportManager.shared.export(
                    items: itemsToExport,
                    destinationDirectory: destination
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.slideView.hudView.showMessage("Exporting \(progress.current) / \(progress.total)...")
                    }
                }

                self.isExporting = false
                let finishMsg = "Exported \(summary.exportedCount) shots (\(summary.totalFilesWritten) files) to ./Picks"
                self.slideView.hudView.showMessage(finishMsg)
                NSSound(named: "Glass")?.play()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                self.isExporting = false
                self.slideView.hudView.showMessage("Export failed: \(error.localizedDescription)")
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
            slideView.hudView.showMessage("Nothing to Undo [⌘Z]")
            return
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        switch action {
        case .compound(let actions):
            for act in actions.reversed() {
                applyUndoSingleAction(act)
            }
            slideView.hudView.showMessage("↩ Undone [⌘Z]")
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
            let starText = previous > 0 ? "★ \(previous)" : "Cleared"
            slideView.hudView.showMessage("↩ Undone Rating: \(starText) [⌘Z]")

        case .pick(let itemID, _, let previous, _):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.pick = previous
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)
            slideView.hudView.showMessage("↩ Undone Flag: \(previous.title) [⌘Z]")

        case .color(let itemID, _, let previous, _):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.color = previous
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)
            slideView.hudView.showMessage("↩ Undone Color: \(previous.title) [⌘Z]")

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
            slideView.hudView.showMessage("↩ Undone Profile: \(profName) [⌘Z]")

        case .rotate(let itemID, _, let direction):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            let reverseDir: RotationDirection = (direction == .clockwise) ? .counterClockwise : .clockwise
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = try? LosslessRotationEngine.rotate(item: item, direction: reverseDir)
                await self?.pipeline.invalidateCache(at: idx)
                Task { @MainActor [weak self] in
                    self?.jumpToRawIndex(idx)
                    self?.slideView.hudView.showMessage("↩ Undone Rotation [⌘Z]")
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
                self.slideView.hudView.showMessage("↩ Restored: \(item.displayName) [⌘Z]")
            }
        }
    }

    public func slideViewRequestRedo() {
        stopSlideshowIfRunning()
        guard let action = cullingUndoManager.popRedo() else {
            slideView.hudView.showMessage("Nothing to Redo [⇧⌘Z]")
            return
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        switch action {
        case .compound(let actions):
            for act in actions {
                applyRedoSingleAction(act)
            }
            slideView.hudView.showMessage("↪ Redone [⇧⌘Z]")
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
            let starText = new > 0 ? "★ \(new)" : "Cleared"
            slideView.hudView.showMessage("↪ Redone Rating: \(starText) [⇧⌘Z]")

        case .pick(let itemID, _, _, let new):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.pick = new
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)
            slideView.hudView.showMessage("↪ Redone Flag: \(new.title) [⇧⌘Z]")

        case .color(let itemID, _, _, let new):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            var meta = cullingData[itemID] ?? CullingMetadata()
            meta.color = new
            cullingData[itemID] = meta
            saveMetadataAsync(meta: meta, for: item)
            jumpToRawIndex(idx)
            slideView.hudView.showMessage("↪ Redone Color: \(new.title) [⇧⌘Z]")

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
            slideView.hudView.showMessage("↪ Redone Profile: \(profName) [⇧⌘Z]")

        case .rotate(let itemID, _, let direction):
            guard let idx = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            let item = allItems[idx]
            Task.detached(priority: .userInitiated) { [weak self] in
                _ = try? LosslessRotationEngine.rotate(item: item, direction: direction)
                await self?.pipeline.invalidateCache(at: idx)
                Task { @MainActor [weak self] in
                    self?.jumpToRawIndex(idx)
                    self?.slideView.hudView.showMessage("↪ Redone Rotation [⇧⌘Z]")
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
                self.slideView.hudView.showMessage("↪ Trashed again [⇧⌘Z]")
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
        slideView.hudView.showMessage("Opening: \(targetURL.lastPathComponent)")
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
