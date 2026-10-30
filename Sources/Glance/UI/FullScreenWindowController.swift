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

    // Phase 3: Histogram & Clipping Warnings
    private var isHistogramVisible: Bool = false
    private var isClippingVisible: Bool = false
    private var isFocusPeakingVisible: Bool = false
    private var isExifVisible: Bool = false

    // Phase 4: Output & Productivity
    private var isSlideshowActive: Bool = false
    private var slideshowInterval: Double = 3.0
    private var slideshowTimer: Timer? = nil

    // Auto Face & Eye Focus Jump
    private var detectedFacesForCurrentSlide: [DetectedFace] = []
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

        let item = allItems[rawIndex]
        let meta = cullingData[item.id] ?? CullingMetadata()

        let formattedSize = item.totalStackSize > 0
            ? ByteCountFormatter.string(fromByteCount: item.totalStackSize, countStyle: .file)
            : nil

        do {
            let decoded = try await pipeline.getImage(at: rawIndex)
            let resText = "\(decoded.originalWidth) × \(decoded.originalHeight)"

            var splitCgImage: CGImage? = nil
            var rightNativeSize: CGSize? = nil
            if slideView.isSplitMode && currentFilteredPos + 1 < filteredIndices.count {
                let nextRaw = filteredIndices[currentFilteredPos + 1]
                if let nextDecoded = try? await pipeline.getImage(at: nextRaw) {
                    splitCgImage = nextDecoded.image
                    rightNativeSize = CGSize(width: nextDecoded.originalWidth, height: nextDecoded.originalHeight)
                }
            }

            let filterBadge = currentFilter == .all ? nil : currentFilter.title

            let info = HudInfo(
                currentIndex: currentFilteredPos,
                totalCount: filteredIndices.count,
                filename: item.displayName,
                dimensions: resText,
                fileSize: formattedSize,
                isRaw: decoded.isRaw || item.rawURL != nil,
                isStacked: item.isStacked,
                isDownscaled: decoded.isDownscaled,
                culling: meta,
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
                exportProgressText: exportProgressText
            )

            // Detect camera brand for tailored profile color science and naming
            let cameraBrand = CameraProfileEngine.detectBrand(for: item, exif: decoded.exif)

            // Apply Camera Profile / Picture Control if active
            let activeProfile = meta.cameraProfile ?? .asShot
            let renderedImage = (activeProfile != .asShot)
                ? (CameraProfileEngine.apply(profile: activeProfile, brand: cameraBrand, to: decoded.image) ?? decoded.image)
                : decoded.image

            let nativeSize = CGSize(width: decoded.originalWidth, height: decoded.originalHeight)
            slideView.displayImage(
                renderedImage,
                nextImage: splitCgImage,
                info: info,
                nativeSize: nativeSize,
                rightNativeSize: rightNativeSize
            )

            // Trigger background async histogram and clipping calculations (Phase 3)
            if isHistogramVisible {
                updateHistogramAsync(for: decoded.image)
            }
            if isClippingVisible {
                updateClippingMaskAsync(for: decoded.image, nextImage: splitCgImage)
            }
            if isFocusPeakingVisible {
                updatePeakingMaskAsync(for: decoded.image, nextImage: splitCgImage)
            }

            // Pre-detect faces asynchronously via Apple Neural Engine (ANE)
            currentFaceIndex = 0
            detectedFacesForCurrentSlide = []
            let currentPath = item.url.path
            Task.detached(priority: .utility) { [weak self] in
                let faces = await FaceDetectionEngine.shared.detectFaces(in: decoded.image, cacheKey: currentPath)
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentRawIndex == rawIndex else { return }
                    self.detectedFacesForCurrentSlide = faces
                }
            }
        } catch {
            let info = HudInfo(
                currentIndex: currentFilteredPos,
                totalCount: filteredIndices.count,
                filename: item.displayName,
                isRaw: item.rawURL != nil,
                isStacked: item.isStacked,
                culling: meta,
                autoAdvance: autoAdvance,
                errorMessage: "Decode error: \(error.localizedDescription)",
                isSlideshow: isSlideshowActive,
                slideshowInterval: slideshowInterval,
                exportProgressText: exportProgressText
            )
            slideView.displayImage(nil, info: info)
            slideView.updateClippingMask(nil, rightMask: nil)
            slideView.updatePeakingMask(nil, rightMask: nil)
        }
    }

    // MARK: - SlideViewDelegate Navigation

    public func slideViewRequestNext() {
        stopSlideshowIfRunning()
        guard !filteredIndices.isEmpty else { return }
        if currentFilteredPos + 1 < filteredIndices.count {
            navigate(toFilteredPos: currentFilteredPos + 1, direction: .forward)
        } else {
            navigate(toFilteredPos: 0, direction: .forward)
        }
    }

    public func slideViewRequestPrevious() {
        stopSlideshowIfRunning()
        guard !filteredIndices.isEmpty else { return }
        if currentFilteredPos - 1 >= 0 {
            navigate(toFilteredPos: currentFilteredPos - 1, direction: .backward)
        } else {
            navigate(toFilteredPos: filteredIndices.count - 1, direction: .backward)
        }
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
        guard let rawIndex = currentRawIndex, !isDeleting else { return }
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

    // MARK: - Batch Purge Rejects

    public func slideViewRequestPurgeRejects() {
        let rejectIndices = allItems.indices.filter { idx in
            let item = allItems[idx]
            return cullingData[item.id]?.pick == .reject
        }

        guard !rejectIndices.isEmpty else {
            slideView.hudView.showMessage("No rejected files to purge.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Purge \(rejectIndices.count) Rejected Files?"
        alert.informativeText = "All stacked RAW, JPEG, and XMP files will be safely moved to macOS Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            self.executePurgeRejects(indices: Set(rejectIndices))
        }
    }

    private func executePurgeRejects(indices: Set<Int>) {
        isDeleting = true
        slideView.hudView.showMessage("Trashing \(indices.count) rejected files...")

        Task {
            var trashedCount = 0
            for idx in indices {
                let item = allItems[idx]
                for fileURL in item.allURLs {
                    if (try? await TrashManager.moveToTrash(url: fileURL)) != nil {
                        trashedCount += 1
                    }
                    if let sidecarURL = XmpSidecarManager.existingSidecarURL(for: fileURL) {
                        _ = try? await TrashManager.moveToTrash(url: sidecarURL)
                    }
                }
                cullingData.removeValue(forKey: item.id)
            }

            await pipeline.removeItems(at: indices)
            let sortedDesc = indices.sorted(by: >)
            for idx in sortedDesc {
                allItems.remove(at: idx)
            }

            self.rebuildFilter()
            self.isDeleting = false

            if self.allItems.isEmpty {
                self.displayEmptyState("Directory is now empty.")
            } else {
                slideView.hudView.showMessage("Moved \(trashedCount) rejected files to Trash.")
                await self.loadAndDisplayCurrent()
            }
        }
    }

    // MARK: - 100% 1:1 Pixel Peep Action

    public func slideViewRequestZoomToggle(mouseLocation: CGPoint) {
        stopSlideshowIfRunning()
        if slideView.isZoomed {
            currentFaceIndex = 0
            slideView.setZoom(false)
        } else {
            guard let rawIndex = currentRawIndex else { return }

            // Instantly zoom the view using the screen-bounded layer first (0ms latency!)
            slideView.setZoom(true, anchorPointInView: mouseLocation)

            // Check if in split mode to decode both left and right images at 100%
            let isSplit = slideView.isSplitMode
            let nextRawIndex: Int? = (isSplit && currentFilteredPos + 1 < filteredIndices.count)
                ? filteredIndices[currentFilteredPos + 1]
                : nil

            // Concurrently fetch the full 100% unconstrained sensor resolution in background
            Task {
                async let leftFullTask = try? self.pipeline.getFullResolutionImage(at: rawIndex)
                async let rightFullTask: DecodedImage? = {
                    if let rIdx = nextRawIndex {
                        return try? await self.pipeline.getFullResolutionImage(at: rIdx)
                    }
                    return nil
                }()

                let (leftFull, rightFull) = await (leftFullTask, rightFullTask)

                if let fullRes = leftFull {
                    let fullDims = CGSize(width: fullRes.originalWidth, height: fullRes.originalHeight)
                    let rightDims = rightFull != nil ? CGSize(width: rightFull!.originalWidth, height: rightFull!.originalHeight) : nil
                    self.slideView.setZoom(
                        true,
                        anchorPointInView: mouseLocation,
                        fullResImage: fullRes.image,
                        originalDimensions: fullDims,
                        rightFullResImage: rightFull?.image,
                        rightOriginalDimensions: rightDims
                    )
                }
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

            let faceIdx = self.currentFaceIndex % faces.count
            let targetFace = faces[faceIdx]
            self.currentFaceIndex += 1

            let label = faces.count > 1
                ? "👁️ Face \(faceIdx + 1)/\(faces.count) (Eye Focus)"
                : "👁️ Eye Focus"

            self.slideView.zoomToNormalizedPoint(targetFace.eyeCenter, label: label)

            if let fullRes = try? await self.pipeline.getFullResolutionImage(at: rawIndex) {
                let fullDims = CGSize(width: fullRes.originalWidth, height: fullRes.originalHeight)
                self.slideView.zoomToNormalizedPoint(
                    targetFace.eyeCenter,
                    fullResImage: fullRes.image,
                    originalDimensions: fullDims
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

        if isHistogramVisible, let rawIndex = currentRawIndex {
            Task {
                if let decoded = try? await pipeline.getImage(at: rawIndex) {
                    updateHistogramAsync(for: decoded.image)
                }
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

        if isClippingVisible, let rawIndex = currentRawIndex {
            Task {
                if let decoded = try? await pipeline.getImage(at: rawIndex) {
                    var nextImg: CGImage? = nil
                    if slideView.isSplitMode && currentFilteredPos + 1 < filteredIndices.count {
                        let nextRaw = filteredIndices[currentFilteredPos + 1]
                        nextImg = (try? await pipeline.getImage(at: nextRaw))?.image
                    }
                    updateClippingMaskAsync(for: decoded.image, nextImage: nextImg)
                }
            }
        } else {
            slideView.updateClippingMask(nil, rightMask: nil)
        }
    }

    public func slideViewToggleFocusPeaking() {
        isFocusPeakingVisible.toggle()
        slideView.setPeakingActive(isFocusPeakingVisible)
        let msg = isFocusPeakingVisible ? "Focus Peaking: ON [⇧F]" : "Focus Peaking: OFF [⇧F]"
        slideView.hudView.showMessage(msg)

        if isFocusPeakingVisible, let rawIndex = currentRawIndex {
            Task {
                if let decoded = try? await pipeline.getImage(at: rawIndex) {
                    var nextImg: CGImage? = nil
                    if slideView.isSplitMode && currentFilteredPos + 1 < filteredIndices.count {
                        let nextRaw = filteredIndices[currentFilteredPos + 1]
                        nextImg = (try? await pipeline.getImage(at: nextRaw))?.image
                    }
                    updatePeakingMaskAsync(for: decoded.image, nextImage: nextImg)
                }
            }
        } else {
            slideView.updatePeakingMask(nil, rightMask: nil)
        }
    }

    private func updateHistogramAsync(for cgImage: CGImage) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let data = HistogramEngine.compute(for: cgImage)
            Task { @MainActor [weak self] in
                self?.slideView.updateHistogram(data)
            }
        }
    }

    private func updateClippingMaskAsync(for cgImage: CGImage, nextImage: CGImage? = nil) {
        let expectedIndex = currentRawIndex
        Task.detached(priority: .userInitiated) { [weak self] in
            let mask = ClippingEngine.generateClippingMask(for: cgImage)
            let rightMask: CGImage? = (nextImage != nil) ? ClippingEngine.generateClippingMask(for: nextImage!) : nil
            Task { @MainActor [weak self] in
                guard let self = self, self.currentRawIndex == expectedIndex else { return }
                self.slideView.updateClippingMask(mask, rightMask: rightMask)
            }
        }
    }

    private func updatePeakingMaskAsync(for cgImage: CGImage, nextImage: CGImage? = nil) {
        let expectedIndex = currentRawIndex
        Task.detached(priority: .userInitiated) { [weak self] in
            let mask = FocusPeakingEngine.generatePeakingMask(for: cgImage)
            let rightMask: CGImage? = (nextImage != nil) ? FocusPeakingEngine.generatePeakingMask(for: nextImage!) : nil
            Task { @MainActor [weak self] in
                guard let self = self, self.currentRawIndex == expectedIndex else { return }
                self.slideView.updatePeakingMask(mask, rightMask: rightMask)
            }
        }
    }

    // MARK: - Camera Profiles & Picture Controls

    public func slideViewCycleCameraProfile() {
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

    // MARK: - Culling Actions

    public func slideViewSetRating(_ rating: Int) {
        guard let rawIndex = currentRawIndex else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let item = allItems[rawIndex]
        var meta = cullingData[item.id] ?? CullingMetadata()
        let previous = meta.rating
        let newRating = (meta.rating == rating) ? 0 : rating
        meta.rating = newRating
        cullingData[item.id] = meta

        cullingUndoManager.record(.rating(itemID: item.id, rawIndex: rawIndex, previous: previous, new: newRating))

        applyCullingUpdate()
        saveMetadataAsync(meta: meta, for: item)
    }

    public func slideViewSetPick(_ pick: PickStatus) {
        guard let rawIndex = currentRawIndex else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let item = allItems[rawIndex]
        var meta = cullingData[item.id] ?? CullingMetadata()
        let previous = meta.pick
        let newPick = (meta.pick == pick) ? .unflagged : pick
        meta.pick = newPick
        cullingData[item.id] = meta

        cullingUndoManager.record(.pick(itemID: item.id, rawIndex: rawIndex, previous: previous, new: newPick))

        applyCullingUpdate()
        saveMetadataAsync(meta: meta, for: item)
    }

    public func slideViewSetColor(_ color: ColorLabel) {
        guard let rawIndex = currentRawIndex else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let item = allItems[rawIndex]
        var meta = cullingData[item.id] ?? CullingMetadata()
        let previous = meta.color
        let newColor = (meta.color == color) ? .none : color
        meta.color = newColor
        cullingData[item.id] = meta

        cullingUndoManager.record(.color(itemID: item.id, rawIndex: rawIndex, previous: previous, new: newColor))

        applyCullingUpdate()
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

            if autoAdvance {
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

    public func slideViewToggleSplitCompare() {
        let newState = !slideView.isSplitMode
        slideView.setSplitMode(newState)
        let modeMsg = newState ? "Burst Compare: 2-UP [S]" : "Single Fullscreen [S]"
        slideView.hudView.showMessage(modeMsg)
        Task {
            await loadAndDisplayCurrent()
        }
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

        // Resolve target items
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
                // If no picks exist, export the currently viewed photo
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
        return
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
}
