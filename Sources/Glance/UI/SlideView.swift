import AppKit
import CoreGraphics
import QuartzCore

@MainActor
public protocol SlideViewDelegate: AnyObject {
    func slideViewRequestNext()
    func slideViewRequestPrevious()
    func slideViewRequestFirst()
    func slideViewRequestLast()
    func slideViewRequestDelete()
    func slideViewRequestPurgeRejects()
    func slideViewToggleFullScreen()
    func slideViewClose()
    func slideViewDidDrop(url: URL)

    // Culling Actions
    func slideViewSetRating(_ rating: Int)
    func slideViewSetPick(_ pick: PickStatus)
    func slideViewSetColor(_ color: ColorLabel)
    func slideViewToggleAutoAdvance()
    func slideViewCycleFilter()
    func slideViewCycleMultiUp()
    func slideViewToggleSplitCompare()
    func slideViewPickWinner(slot: Int)
    func slideViewCommitSplitMatchup()
    func slideViewHoverPaneChanged(to slot: Int)

    // 100% Zoom Action
    func slideViewRequestZoomToggle(mouseLocation: CGPoint)
    func slideViewJumpToFaceEye()

    // Phase 3: Histogram & Exposure Clipping
    func slideViewToggleHistogram()
    func slideViewToggleClipping()
    func slideViewToggleFocusPeaking()
    func slideViewToggleExif()
    func slideViewCycleCameraProfile()

    // Undo & Redo Actions
    func slideViewRequestUndo()
    func slideViewRequestRedo()
    func slideViewRequestOpenInEditor()

    // Phase 4: Output & Workflow Productivity
    func slideViewRequestExport()
    func slideViewRotate(direction: RotationDirection)
    func slideViewToggleSlideshow()
    func slideViewStopSlideshow()
    func slideViewAdjustSlideshowInterval(increase: Bool)
}

public extension SlideViewDelegate {
    func slideViewToggleSplitCompare() {
        slideViewCycleMultiUp()
    }
    func slideViewPickWinner(slot: Int) {}
    func slideViewCommitSplitMatchup() {
        slideViewRequestNext()
    }
}

/// Ultra-responsive, zero-latency layer-backed NSView.
/// Supports single image full-screen display, 2-UP pair split compare, 4-UP quad burst compare,
/// instant 100% 1:1 pixel peeping with smooth pan/drag, live RGB histogram,
/// dynamic pane hover inspection, and camera-style exposure clipping warnings ("blinkies").
@MainActor
public final class SlideView: NSView {
    public weak var delegate: SlideViewDelegate?

    private let paneContainerLayers: [CALayer] = (0..<4).map { _ in CALayer() }
    private let paneImageLayers: [CALayer] = (0..<4).map { _ in CALayer() }
    private let paneClippingLayers: [CALayer] = (0..<4).map { _ in CALayer() }
    private let panePeakingLayers: [CALayer] = (0..<4).map { _ in CALayer() }

    // Backward-compatibility aliases
    private var leftContainerLayer: CALayer { paneContainerLayers[0] }
    private var leftImageLayer: CALayer { paneImageLayers[0] }
    private var leftClippingLayer: CALayer { paneClippingLayers[0] }
    private var leftPeakingLayer: CALayer { panePeakingLayers[0] }

    private var rightContainerLayer: CALayer { paneContainerLayers[1] }
    private var rightImageLayer: CALayer { paneImageLayers[1] }
    private var rightClippingLayer: CALayer { paneClippingLayers[1] }
    private var rightPeakingLayer: CALayer { panePeakingLayers[1] }

    private var containerLayer: CALayer { paneContainerLayers[0] }
    private var imageLayer: CALayer { paneImageLayers[0] }
    private var splitLayer: CALayer { paneImageLayers[1] }

    public let hudView = GlassHudView()
    public let histogramHud = HistogramHudView()
    public let exifHud = ExifHudView()
    public let quickHelpView = QuickHelpView()

    public let splitBadges: [SplitPaneBadgeView] = (1...4).map { SplitPaneBadgeView(slot: $0) }
    public var leftSplitBadge: SplitPaneBadgeView { splitBadges[0] }
    public var rightSplitBadge: SplitPaneBadgeView { splitBadges[1] }

    private var histogramTopConstraint: NSLayoutConstraint?
    private var exifTopConstraint: NSLayoutConstraint?

    public private(set) var multiUpMode: MultiUpMode = .single
    public var isSplitMode: Bool { multiUpMode != .single }
    public private(set) var hoveredSplitSlot: Int = 1
    public private(set) var isZoomed: Bool = false
    public private(set) var isClippingActive: Bool = false
    public private(set) var isPeakingActive: Bool = false

    // Zoom & Pan state across up to 4 panes
    private var paneImageSizes: [CGSize] = Array(repeating: .zero, count: 4)
    private var zoomPanOffsets: [CGPoint] = Array(repeating: .zero, count: 4)
    private var dragStartOffsets: [CGPoint] = Array(repeating: .zero, count: 4)
    private var dragStartMouse: CGPoint = .zero
    private var isDragging: Bool = false

    // Compatibility getters/setters
    private var currentImageSize: CGSize {
        get { paneImageSizes[0] }
        set { paneImageSizes[0] = newValue }
    }
    private var rightImageSize: CGSize {
        get { paneImageSizes[1] }
        set { paneImageSizes[1] = newValue }
    }
    private var zoomPanOffset: CGPoint {
        get { zoomPanOffsets[0] }
        set { zoomPanOffsets[0] = newValue }
    }
    private var rightZoomPanOffset: CGPoint {
        get { zoomPanOffsets[1] }
        set { zoomPanOffsets[1] = newValue }
    }

    private var cursorTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private var lastZPressTime: TimeInterval = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
        setupHud()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
        setupHud()
        registerForDraggedTypes([.fileURL])
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        for i in 0..<4 {
            let container = paneContainerLayers[i]
            container.backgroundColor = NSColor.black.cgColor
            container.masksToBounds = true
            container.isHidden = (i > 0)
            layer?.addSublayer(container)

            let img = paneImageLayers[i]
            img.backgroundColor = NSColor.black.cgColor
            img.isOpaque = true
            img.actions = [
                "contents": NSNull(),
                "bounds": NSNull(),
                "position": NSNull(),
                "transform": NSNull()
            ]
            container.addSublayer(img)

            let clip = paneClippingLayers[i]
            clip.backgroundColor = NSColor.clear.cgColor
            clip.contentsGravity = .resizeAspect
            clip.actions = [
                "contents": NSNull(),
                "bounds": NSNull(),
                "position": NSNull(),
                "transform": NSNull(),
                "opacity": NSNull()
            ]
            clip.isHidden = true
            img.addSublayer(clip)

            let peak = panePeakingLayers[i]
            peak.backgroundColor = NSColor.clear.cgColor
            peak.contentsGravity = .resizeAspect
            peak.actions = [
                "contents": NSNull(),
                "bounds": NSNull(),
                "position": NSNull(),
                "transform": NSNull(),
                "opacity": NSNull()
            ]
            peak.isHidden = true
            img.addSublayer(peak)
        }
    }

    private func setupHud() {
        hudView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hudView)

        histogramHud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(histogramHud)
        histogramHud.onToggleClipping = { [weak self] in
            self?.delegate?.slideViewToggleClipping()
        }

        exifHud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(exifHud)

        quickHelpView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(quickHelpView)

        // Split Badges: positioned manually via frames in updateLayerLayout
        for badge in splitBadges {
            badge.translatesAutoresizingMaskIntoConstraints = true
            addSubview(badge)
            badge.isHidden = true
        }

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: centerXAnchor),
            hudView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            hudView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            hudView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            hudView.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),

            {
                let c = histogramHud.topAnchor.constraint(equalTo: topAnchor, constant: 28)
                self.histogramTopConstraint = c
                return c
            }(),
            histogramHud.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            histogramHud.widthAnchor.constraint(equalToConstant: 284),

            {
                let c = exifHud.topAnchor.constraint(equalTo: topAnchor, constant: 28)
                self.exifTopConstraint = c
                return c
            }(),
            exifHud.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            exifHud.widthAnchor.constraint(equalToConstant: 284),

            quickHelpView.centerXAnchor.constraint(equalTo: centerXAnchor),
            quickHelpView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    public override func layout() {
        super.layout()
        updateLayerLayout(animated: false)
    }

    private func updateLayerLayout(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }

        let scale = window?.backingScaleFactor ?? 2.0
        let totalW = bounds.width
        let totalH = bounds.height

        switch multiUpMode {
        case .single:
            for i in 1..<4 {
                paneContainerLayers[i].frame = .zero
                paneContainerLayers[i].isHidden = true
                splitBadges[i].isHidden = true
            }
            splitBadges[0].isHidden = true

            paneContainerLayers[0].frame = bounds
            paneContainerLayers[0].isHidden = false

            if isZoomed && paneImageSizes[0].width > 0 && paneImageSizes[0].height > 0 {
                let nativeW = paneImageSizes[0].width / scale
                let nativeH = paneImageSizes[0].height / scale

                paneImageLayers[0].contentsGravity = .resize
                paneImageLayers[0].bounds = CGRect(x: 0, y: 0, width: nativeW, height: nativeH)

                let maxPanX = max(0, (nativeW - totalW) / 2)
                let maxPanY = max(0, (nativeH - totalH) / 2)
                zoomPanOffsets[0].x = min(maxPanX, max(-maxPanX, zoomPanOffsets[0].x))
                zoomPanOffsets[0].y = min(maxPanY, max(-maxPanY, zoomPanOffsets[0].y))

                paneImageLayers[0].position = CGPoint(
                    x: (totalW / 2) + zoomPanOffsets[0].x,
                    y: (totalH / 2) + zoomPanOffsets[0].y
                )
            } else {
                paneImageLayers[0].contentsGravity = .resizeAspect
                paneImageLayers[0].bounds = bounds
                paneImageLayers[0].position = CGPoint(x: bounds.midX, y: bounds.midY)
                zoomPanOffsets[0] = .zero
            }

        case .twoUp:
            for i in 2..<4 {
                paneContainerLayers[i].frame = .zero
                paneContainerLayers[i].isHidden = true
                splitBadges[i].isHidden = true
            }

            let halfWidth = floor((totalW - 2) / 2)
            let frames: [CGRect] = [
                CGRect(x: 0, y: 0, width: halfWidth, height: totalH),
                CGRect(x: totalW - halfWidth, y: 0, width: halfWidth, height: totalH)
            ]

            let badgeW: CGFloat = min(360, max(220, halfWidth - 48))
            let leftBadgeX = max(16, (halfWidth - badgeW) / 2)
            let rightBadgeX = max(totalW - halfWidth + 16, (totalW - halfWidth) + (halfWidth - badgeW) / 2)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            splitBadges[0].frame = CGRect(x: leftBadgeX, y: totalH - 50, width: badgeW, height: 34)
            splitBadges[1].frame = CGRect(x: rightBadgeX, y: totalH - 50, width: badgeW, height: 34)
            splitBadges[0].isHidden = (paneImageLayers[0].contents == nil)
            splitBadges[1].isHidden = (paneImageLayers[1].contents == nil)
            splitBadges[0].isActiveSlot = (hoveredSplitSlot == 1)
            splitBadges[1].isActiveSlot = (hoveredSplitSlot == 2)
            CATransaction.commit()

            for i in 0..<2 {
                let pFrame = frames[i]
                paneContainerLayers[i].frame = pFrame
                paneContainerLayers[i].isHidden = (paneImageLayers[i].contents == nil)

                if isZoomed {
                    let imgSize = paneImageSizes[i].width > 0 ? paneImageSizes[i] : paneImageSizes[0]
                    let nativeW = (imgSize.width > 0 ? imgSize.width : halfWidth * scale) / scale
                    let nativeH = (imgSize.height > 0 ? imgSize.height : totalH * scale) / scale

                    paneImageLayers[i].contentsGravity = .resize
                    paneImageLayers[i].bounds = CGRect(x: 0, y: 0, width: nativeW, height: nativeH)

                    let maxPanX = max(0, (nativeW - halfWidth) / 2)
                    let maxPanY = max(0, (nativeH - totalH) / 2)

                    zoomPanOffsets[i].x = min(maxPanX, max(-maxPanX, zoomPanOffsets[i].x))
                    zoomPanOffsets[i].y = min(maxPanY, max(-maxPanY, zoomPanOffsets[i].y))

                    paneImageLayers[i].position = CGPoint(
                        x: (halfWidth / 2) + zoomPanOffsets[i].x,
                        y: (totalH / 2) + zoomPanOffsets[i].y
                    )
                } else {
                    paneImageLayers[i].contentsGravity = .resizeAspect
                    paneImageLayers[i].bounds = CGRect(origin: .zero, size: pFrame.size)
                    paneImageLayers[i].position = CGPoint(x: pFrame.width / 2, y: pFrame.height / 2)
                    zoomPanOffsets[i] = .zero
                }
            }

        case .fourUp:
            let halfWidth = floor((totalW - 2) / 2)
            let halfHeight = floor((totalH - 2) / 2)

            // Slot 1: TL (x: 0, y: totalH - halfHeight)
            // Slot 2: TR (x: totalW - halfWidth, y: totalH - halfHeight)
            // Slot 3: BL (x: 0, y: 0)
            // Slot 4: BR (x: totalW - halfWidth, y: 0)
            let frames: [CGRect] = [
                CGRect(x: 0, y: totalH - halfHeight, width: halfWidth, height: halfHeight),
                CGRect(x: totalW - halfWidth, y: totalH - halfHeight, width: halfWidth, height: halfHeight),
                CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight),
                CGRect(x: totalW - halfWidth, y: 0, width: halfWidth, height: halfHeight)
            ]

            let badgeW: CGFloat = min(340, max(180, halfWidth - 36))
            let leftBadgeX = max(12, (halfWidth - badgeW) / 2)
            let rightBadgeX = max(totalW - halfWidth + 12, (totalW - halfWidth) + (halfWidth - badgeW) / 2)

            let topBadgeY = totalH - 46
            let bottomBadgeY = halfHeight - 46

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            splitBadges[0].frame = CGRect(x: leftBadgeX, y: topBadgeY, width: badgeW, height: 32)
            splitBadges[1].frame = CGRect(x: rightBadgeX, y: topBadgeY, width: badgeW, height: 32)
            splitBadges[2].frame = CGRect(x: leftBadgeX, y: bottomBadgeY, width: badgeW, height: 32)
            splitBadges[3].frame = CGRect(x: rightBadgeX, y: bottomBadgeY, width: badgeW, height: 32)

            for i in 0..<4 {
                splitBadges[i].isHidden = (paneImageLayers[i].contents == nil)
                splitBadges[i].isActiveSlot = (hoveredSplitSlot == (i + 1))
            }
            CATransaction.commit()

            for i in 0..<4 {
                let pFrame = frames[i]
                paneContainerLayers[i].frame = pFrame
                paneContainerLayers[i].isHidden = (paneImageLayers[i].contents == nil)

                if isZoomed {
                    let imgSize = paneImageSizes[i].width > 0 ? paneImageSizes[i] : paneImageSizes[0]
                    let nativeW = (imgSize.width > 0 ? imgSize.width : halfWidth * scale) / scale
                    let nativeH = (imgSize.height > 0 ? imgSize.height : halfHeight * scale) / scale

                    paneImageLayers[i].contentsGravity = .resize
                    paneImageLayers[i].bounds = CGRect(x: 0, y: 0, width: nativeW, height: nativeH)

                    let maxPanX = max(0, (nativeW - halfWidth) / 2)
                    let maxPanY = max(0, (nativeH - halfHeight) / 2)

                    zoomPanOffsets[i].x = min(maxPanX, max(-maxPanX, zoomPanOffsets[i].x))
                    zoomPanOffsets[i].y = min(maxPanY, max(-maxPanY, zoomPanOffsets[i].y))

                    paneImageLayers[i].position = CGPoint(
                        x: (halfWidth / 2) + zoomPanOffsets[i].x,
                        y: (halfHeight / 2) + zoomPanOffsets[i].y
                    )
                } else {
                    paneImageLayers[i].contentsGravity = .resizeAspect
                    paneImageLayers[i].bounds = CGRect(origin: .zero, size: pFrame.size)
                    paneImageLayers[i].position = CGPoint(x: pFrame.width / 2, y: pFrame.height / 2)
                    zoomPanOffsets[i] = .zero
                }
            }
        }

        for i in 0..<4 {
            paneClippingLayers[i].frame = paneImageLayers[i].bounds
            paneClippingLayers[i].contentsGravity = paneImageLayers[i].contentsGravity
            panePeakingLayers[i].frame = paneImageLayers[i].bounds
            panePeakingLayers[i].contentsGravity = paneImageLayers[i].contentsGravity
        }

        CATransaction.commit()
    }

    public func displayMultiUp(
        images: [CGImage?],
        nativeSizes: [CGSize] = [],
        splitInfos: [SplitPaneInfo?] = [],
        info: HudInfo? = nil
    ) {
        for i in 0..<4 {
            if i < nativeSizes.count, nativeSizes[i].width > 0 {
                paneImageSizes[i] = nativeSizes[i]
            } else if i < images.count, let img = images[i] {
                paneImageSizes[i] = CGSize(width: img.width, height: img.height)
            } else {
                paneImageSizes[i] = .zero
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<4 {
            let img = (i < images.count) ? images[i] : nil
            paneImageLayers[i].contents = img
        }
        CATransaction.commit()

        updateLayerLayout(animated: false)

        if let info = info {
            hudView.update(with: info)
            exifHud.update(with: info.exif, dimensions: info.dimensions, fileSize: info.fileSize)
        }

        for i in 0..<4 {
            let sInfo = (i < splitInfos.count) ? splitInfos[i] : nil
            splitBadges[i].update(with: sInfo)
        }
    }

    public func displayImage(
        _ cgImage: CGImage?,
        nextImage: CGImage? = nil,
        info: HudInfo? = nil,
        nativeSize: CGSize? = nil,
        rightNativeSize: CGSize? = nil,
        leftSplitInfo: SplitPaneInfo? = nil,
        rightSplitInfo: SplitPaneInfo? = nil
    ) {
        let images: [CGImage?] = [cgImage, nextImage, nil, nil]
        var sizes: [CGSize] = [.zero, .zero, .zero, .zero]
        if let s = nativeSize { sizes[0] = s }
        if let rs = rightNativeSize { sizes[1] = rs }
        let splitInfos: [SplitPaneInfo?] = [leftSplitInfo, rightSplitInfo, nil, nil]
        displayMultiUp(images: images, nativeSizes: sizes, splitInfos: splitInfos, info: info)
    }

    public func updateSplitAesthetics(left: AestheticScoreResult?, right: AestheticScoreResult?) {
        splitBadges[0].updateAestheticScore(left)
        splitBadges[1].updateAestheticScore(right)
    }

    public func updateSlotAesthetics(slot: Int, score: AestheticScoreResult?) {
        guard slot >= 1 && slot <= 4 else { return }
        splitBadges[slot - 1].updateAestheticScore(score)
    }

    public func updateAestheticScore(_ score: AestheticScoreResult?) {
        hudView.updateAestheticScore(score)
    }

    public func updateSplitScene(description: String?) {
        splitBadges[0].updateBurstDescription(description)
        splitBadges[1].updateBurstDescription(description)
    }

    public func updateSlotScene(slot: Int, description: String?) {
        guard slot >= 1 && slot <= 4 else { return }
        splitBadges[slot - 1].updateBurstDescription(description)
    }

    public func setMultiUpMode(_ mode: MultiUpMode) {
        multiUpMode = mode
        hoveredSplitSlot = 1
        for i in 0..<4 {
            splitBadges[i].isActiveSlot = (i == 0)
        }
        histogramTopConstraint?.constant = (mode != .single) ? 62 : 28
        exifTopConstraint?.constant = (mode != .single) ? 62 : 28
        needsLayout = true
    }

    public func setSplitMode(_ enabled: Bool) {
        setMultiUpMode(enabled ? .twoUp : .single)
    }

    public func displayMessage(_ message: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<4 {
            paneImageLayers[i].contents = nil
            paneClippingLayers[i].contents = nil
            panePeakingLayers[i].contents = nil
            splitBadges[i].isHidden = true
        }
        CATransaction.commit()

        hudView.showMessage(message)
    }

    public func toggleHud() {
        hudView.togglePersistent()
    }

    public func toggleHelp() {
        quickHelpView.toggle()
    }

    // MARK: - Phase 3: Histogram & Clipping Warnings ("Blinkies")

    public func updateHistogram(_ data: HistogramData, slot: Int? = nil) {
        histogramHud.update(with: data, slot: slot)
    }

    public func updateDualHistogram(left: HistogramData, right: HistogramData) {
        let active = (hoveredSplitSlot == 2) ? right : left
        histogramHud.update(with: active, slot: hoveredSplitSlot)
    }

    public func setHistogramVisible(_ visible: Bool) {
        histogramHud.setVisible(visible)
    }

    public func setExifVisible(_ visible: Bool) {
        exifHud.setVisible(visible)
    }

    public func setClippingActive(_ active: Bool) {
        isClippingActive = active
        for i in 0..<4 {
            paneClippingLayers[i].isHidden = !active
        }

        if active {
            startBlinkyAnimation()
        } else {
            stopBlinkyAnimation()
        }
    }

    public func updateClippingMasks(_ masks: [CGImage?]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<4 {
            paneClippingLayers[i].contents = (i < masks.count) ? masks[i] : nil
        }
        CATransaction.commit()
    }

    public func updateClippingMask(_ mask: CGImage?, rightMask: CGImage? = nil) {
        updateClippingMasks([mask, rightMask, nil, nil])
    }

    private func startBlinkyAnimation() {
        for layer in paneClippingLayers {
            layer.removeAnimation(forKey: "blinkyPulse")
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 0.20
            anim.toValue = 0.95
            anim.duration = 0.50
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.beginTime = CACurrentMediaTime()
            layer.add(anim, forKey: "blinkyPulse")
        }
    }

    private func stopBlinkyAnimation() {
        for layer in paneClippingLayers {
            layer.removeAnimation(forKey: "blinkyPulse")
        }
    }

    public func setPeakingActive(_ active: Bool) {
        isPeakingActive = active
        for i in 0..<4 {
            panePeakingLayers[i].isHidden = !active
        }
    }

    public func updatePeakingMasks(_ masks: [CGImage?]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<4 {
            panePeakingLayers[i].contents = (i < masks.count) ? masks[i] : nil
        }
        CATransaction.commit()
    }

    public func updatePeakingMask(_ mask: CGImage?, rightMask: CGImage? = nil) {
        updatePeakingMasks([mask, rightMask, nil, nil])
    }

    // MARK: - 100% Zoom & Pan Mechanics

    /// Converts a point in local pane coordinates to normalized [0, 1] image coordinates
    private func imageNormalizedPoint(fromPaneLocalPoint pt: CGPoint, paneSize: CGSize, imageSize: CGSize) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0, paneSize.width > 0, paneSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let fitScale = min(paneSize.width / imageSize.width, paneSize.height / imageSize.height)
        let renderedW = imageSize.width * fitScale
        let renderedH = imageSize.height * fitScale
        let originX = (paneSize.width - renderedW) / 2.0
        let originY = (paneSize.height - renderedH) / 2.0

        let normX = (pt.x - originX) / renderedW
        let normY = (pt.y - originY) / renderedH

        return CGPoint(
            x: max(0.0, min(1.0, normX)),
            y: max(0.0, min(1.0, normY))
        )
    }

    public func setZoom(
        _ zoomed: Bool,
        anchorPointInView: CGPoint? = nil,
        fullResImage: CGImage? = nil,
        originalDimensions: CGSize? = nil,
        rightFullResImage: CGImage? = nil,
        rightOriginalDimensions: CGSize? = nil,
        multiFullResImages: [CGImage?] = [],
        multiOriginalDimensions: [CGSize] = []
    ) {
        if let dims = originalDimensions {
            paneImageSizes[0] = dims
        }
        if let fullImg = fullResImage {
            paneImageLayers[0].contents = fullImg
        }
        if let rDims = rightOriginalDimensions {
            paneImageSizes[1] = rDims
        }
        if let rFullImg = rightFullResImage {
            paneImageLayers[1].contents = rFullImg
        }
        for (i, img) in multiFullResImages.enumerated() where i < 4 {
            if let img = img { paneImageLayers[i].contents = img }
        }
        for (i, dims) in multiOriginalDimensions.enumerated() where i < 4 {
            if dims.width > 0 { paneImageSizes[i] = dims }
        }

        if isZoomed == zoomed {
            if isZoomed && (!multiFullResImages.isEmpty || fullResImage != nil || rightFullResImage != nil) {
                updateLayerLayout(animated: false)
            }
            return
        }

        isZoomed = zoomed
        hudView.updateZoomState(isZoomed)

        if isZoomed {
            let mousePt = anchorPointInView ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let scale = window?.backingScaleFactor ?? 2.0
            let totalW = bounds.width
            let totalH = bounds.height

            let clickedPaneIndex: Int
            let clickedPaneFrame: CGRect
            let paneW: CGFloat
            let paneH: CGFloat

            switch multiUpMode {
            case .single:
                clickedPaneIndex = 0
                clickedPaneFrame = bounds
                paneW = bounds.width
                paneH = bounds.height
            case .twoUp:
                let halfWidth = floor((totalW - 2) / 2)
                clickedPaneIndex = (mousePt.x > halfWidth) ? 1 : 0
                clickedPaneFrame = (clickedPaneIndex == 1)
                    ? CGRect(x: totalW - halfWidth, y: 0, width: halfWidth, height: totalH)
                    : CGRect(x: 0, y: 0, width: halfWidth, height: totalH)
                paneW = halfWidth
                paneH = totalH
            case .fourUp:
                let halfWidth = floor((totalW - 2) / 2)
                let halfHeight = floor((totalH - 2) / 2)
                let isTop = mousePt.y >= (totalH / 2)
                let isRight = mousePt.x >= (totalW / 2)
                if isTop && !isRight { clickedPaneIndex = 0 }
                else if isTop && isRight { clickedPaneIndex = 1 }
                else if !isTop && !isRight { clickedPaneIndex = 2 }
                else { clickedPaneIndex = 3 }

                switch clickedPaneIndex {
                case 0: clickedPaneFrame = CGRect(x: 0, y: totalH - halfHeight, width: halfWidth, height: halfHeight)
                case 1: clickedPaneFrame = CGRect(x: totalW - halfWidth, y: totalH - halfHeight, width: halfWidth, height: halfHeight)
                case 2: clickedPaneFrame = CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight)
                default: clickedPaneFrame = CGRect(x: totalW - halfWidth, y: 0, width: halfWidth, height: halfHeight)
                }
                paneW = halfWidth
                paneH = halfHeight
            }

            let paneLocalPt = CGPoint(x: mousePt.x - clickedPaneFrame.minX, y: mousePt.y - clickedPaneFrame.minY)
            let clickedImgSize = paneImageSizes[clickedPaneIndex].width > 0 ? paneImageSizes[clickedPaneIndex] : paneImageSizes[0]
            let normPt = imageNormalizedPoint(fromPaneLocalPoint: paneLocalPt, paneSize: clickedPaneFrame.size, imageSize: clickedImgSize)

            for i in 0..<4 {
                let imgSize = paneImageSizes[i].width > 0 ? paneImageSizes[i] : clickedImgSize
                let nativeW = (imgSize.width > 0 ? imgSize.width : paneW * scale) / scale
                let nativeH = (imgSize.height > 0 ? imgSize.height : paneH * scale) / scale
                zoomPanOffsets[i] = CGPoint(
                    x: (0.5 - normPt.x) * nativeW,
                    y: (0.5 - normPt.y) * nativeH
                )
            }
        } else {
            for i in 0..<4 {
                zoomPanOffsets[i] = .zero
            }
        }

        updateLayerLayout(animated: true)
    }

    /// Zooms into 100% 1:1 pixel peeping centered precisely on a normalized image coordinate (e.g. detected subject eye)
    public func zoomToNormalizedPoint(
        _ normPoint: CGPoint,
        rightNormPoint: CGPoint? = nil,
        fullResImage: CGImage? = nil,
        originalDimensions: CGSize? = nil,
        rightFullResImage: CGImage? = nil,
        rightOriginalDimensions: CGSize? = nil,
        label: String? = nil
    ) {
        if let dims = originalDimensions {
            paneImageSizes[0] = dims
        }
        if let fullImg = fullResImage {
            paneImageLayers[0].contents = fullImg
        }
        if let rDims = rightOriginalDimensions {
            paneImageSizes[1] = rDims
        }
        if let rFullImg = rightFullResImage {
            paneImageLayers[1].contents = rFullImg
        }

        isZoomed = true
        hudView.updateZoomState(true)

        let scale = window?.backingScaleFactor ?? 2.0
        let totalW = bounds.width
        let totalH = bounds.height

        if multiUpMode == .single {
            let nativeW = paneImageSizes[0].width > 0 ? (paneImageSizes[0].width / scale) : totalW
            let nativeH = paneImageSizes[0].height > 0 ? (paneImageSizes[0].height / scale) : totalH
            zoomPanOffsets[0] = CGPoint(
                x: (0.5 - normPoint.x) * nativeW,
                y: (0.5 - normPoint.y) * nativeH
            )
        } else {
            let halfWidth = floor((totalW - 2) / 2)
            let halfHeight = (multiUpMode == .fourUp) ? floor((totalH - 2) / 2) : totalH

            for i in 0..<4 {
                let pt = (i == 1 && rightNormPoint != nil) ? rightNormPoint! : normPoint
                let imgSize = paneImageSizes[i].width > 0 ? paneImageSizes[i] : paneImageSizes[0]
                let nativeW = imgSize.width > 0 ? (imgSize.width / scale) : halfWidth
                let nativeH = imgSize.height > 0 ? (imgSize.height / scale) : halfHeight
                zoomPanOffsets[i] = CGPoint(
                    x: (0.5 - pt.x) * nativeW,
                    y: (0.5 - pt.y) * nativeH
                )
            }
        }

        updateLayerLayout(animated: true)

        if let msg = label {
            hudView.showMessage(msg)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        delegate?.slideViewStopSlideshow()

        if quickHelpView.alphaValue > 0.0 {
            let mouseInHelp = quickHelpView.convert(event.locationInWindow, from: nil)
            if quickHelpView.bounds.contains(mouseInHelp) {
                quickHelpView.toggleExpansion()
            } else {
                quickHelpView.dismiss()
            }
            return
        }

        if hudView.alphaValue > 0.0 {
            let mouseInHud = hudView.convert(event.locationInWindow, from: nil)
            if hudView.handleMouseDown(at: mouseInHud) {
                return
            }
        }

        let mousePt = convert(event.locationInWindow, from: nil)

        // Focus slot under cursor
        let clickedSlot: Int
        switch multiUpMode {
        case .single:
            clickedSlot = 1
        case .twoUp:
            let halfWidth = bounds.width / 2
            clickedSlot = (mousePt.x > halfWidth) ? 2 : 1
        case .fourUp:
            let isTop = mousePt.y >= (bounds.height / 2)
            let isRight = mousePt.x >= (bounds.width / 2)
            if isTop && !isRight { clickedSlot = 1 }
            else if isTop && isRight { clickedSlot = 2 }
            else if !isTop && !isRight { clickedSlot = 3 }
            else { clickedSlot = 4 }
        }

        if clickedSlot != hoveredSplitSlot {
            hoveredSplitSlot = clickedSlot
            for i in 0..<4 {
                splitBadges[i].isActiveSlot = (clickedSlot == i + 1)
            }
            delegate?.slideViewHoverPaneChanged(to: clickedSlot)
        }

        if !isZoomed {
            // Click to zoom in
            delegate?.slideViewRequestZoomToggle(mouseLocation: mousePt)
        } else {
            // Start panning
            isDragging = true
            dragStartMouse = mousePt
            for i in 0..<4 {
                dragStartOffsets[i] = zoomPanOffsets[i]
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isZoomed && isDragging else { return }
        let currentMouse = convert(event.locationInWindow, from: nil)
        let deltaX = currentMouse.x - dragStartMouse.x
        let deltaY = currentMouse.y - dragStartMouse.y

        for i in 0..<4 {
            zoomPanOffsets[i] = CGPoint(
                x: dragStartOffsets[i].x + deltaX,
                y: dragStartOffsets[i].y + deltaY
            )
        }

        updateLayerLayout(animated: false)
    }

    public override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard isZoomed else {
            super.scrollWheel(with: event)
            return
        }

        // Two-finger trackpad panning when zoomed in
        for i in 0..<4 {
            zoomPanOffsets[i].x += event.scrollingDeltaX
            zoomPanOffsets[i].y -= event.scrollingDeltaY
        }
        updateLayerLayout(animated: false)
    }

    // MARK: - Keyboard Handling

    public override var acceptsFirstResponder: Bool {
        return true
    }

    public override func keyDown(with event: NSEvent) {
        resetCursorTimer()

        let chars = event.charactersIgnoringModifiers ?? ""
        let lower = chars.lowercased()
        let isShift = event.modifierFlags.contains(.shift)
        let isCmd = event.modifierFlags.contains(.command)

        // Esc (KeyCode 53) or 'Q' (KeyCode 12): Unequivocally quit Glance to reveal Finder
        if event.keyCode == 53 || lower == "q" || event.keyCode == 12 {
            delegate?.slideViewClose()
            return
        }

        // Multi-Level Undo (Cmd + Z) & Redo (Cmd + Shift + Z)
        if isCmd && (lower == "z" || event.keyCode == 6) {
            delegate?.slideViewStopSlideshow()
            if isShift {
                delegate?.slideViewRequestRedo()
            } else {
                delegate?.slideViewRequestUndo()
            }
            return
        }

        // External App Quick Handoff (Cmd + Enter or Cmd + O)
        if isCmd && (lower == "\r" || event.keyCode == 36 || lower == "o" || event.keyCode == 31) {
            delegate?.slideViewStopSlideshow()
            delegate?.slideViewRequestOpenInEditor()
            return
        }

        if quickHelpView.alphaValue > 0.0 {
            // Space key toggles between compact and expanded cheatsheet
            if event.keyCode == 49 {
                quickHelpView.toggleExpansion()
                return
            }
            // "?" toggles cheatsheet
            if chars == "?" || (event.keyCode == 44 && isShift) {
                quickHelpView.dismiss()
                return
            }
            // Other inputs dismiss cheatsheet and proceed
            quickHelpView.dismiss()
        }

        // --- Layout-Independent Primary Hotkeys ---
        // Rotate Right 90°: 'R' or ']'
        if lower == "r" || chars == "]" || event.keyCode == 30 || event.keyCode == 15 {
            delegate?.slideViewStopSlideshow()
            delegate?.slideViewRotate(direction: .clockwise)
            return
        }

        // Rotate Left 90°: 'L' or '['
        if lower == "l" || chars == "[" || event.keyCode == 33 || event.keyCode == 37 {
            delegate?.slideViewStopSlideshow()
            delegate?.slideViewRotate(direction: .counterClockwise)
            return
        }

        // Quick Export: 'E'
        if lower == "e" || event.keyCode == 14 {
            delegate?.slideViewStopSlideshow()
            delegate?.slideViewRequestExport()
            return
        }

        // Slideshow Toggle: Return / Enter
        if lower == "\r" || event.keyCode == 36 || event.keyCode == 76 {
            delegate?.slideViewToggleSlideshow()
            return
        }

        // Slideshow Interval Adjust: "+" / "=" to increase, "-" / "_" to decrease
        if chars == "+" || chars == "=" || event.keyCode == 24 || event.keyCode == 69 {
            delegate?.slideViewAdjustSlideshowInterval(increase: true)
            return
        }
        if chars == "-" || chars == "_" || event.keyCode == 27 || event.keyCode == 78 {
            delegate?.slideViewAdjustSlideshowInterval(increase: false)
            return
        }

        // Theme Toggle: 'T' or 'D'
        if lower == "t" || lower == "d" || event.keyCode == 17 || event.keyCode == 2 {
            ThemeManager.shared.toggleTheme()
            hudView.pulse()
            for badge in splitBadges {
                badge.updateTheme()
            }
            return
        }

        // 100% Zoom & Auto Face/Eye Jump: 'Z' (KeyCode 6)
        if lower == "z" || event.keyCode == 6 {
            delegate?.slideViewStopSlideshow()
            if isShift {
                delegate?.slideViewJumpToFaceEye()
            } else {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastZPressTime < 0.35 {
                    delegate?.slideViewJumpToFaceEye()
                } else {
                    let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: bounds.midX, y: bounds.midY)
                    let localPt = convert(mouseInWindow, from: nil)
                    delegate?.slideViewRequestZoomToggle(mouseLocation: localPt)
                }
                lastZPressTime = now
            }
            return
        }

        // Focus Peaking: Shift + F
        if isShift && (lower == "f" || event.keyCode == 3) {
            delegate?.slideViewToggleFocusPeaking()
            return
        }

        // Camera Picture Profile / Film Simulation: 'V' (KeyCode 9)
        if lower == "v" || event.keyCode == 9 {
            delegate?.slideViewCycleCameraProfile()
            return
        }

        // Quick Help Cheatsheet: '?' only (Shift + /)
        if chars == "?" || (event.keyCode == 44 && isShift) {
            toggleHelp()
            return
        }

        // Numbers 0..5 (Ratings) & 6..9 (Colors)
        if !isCmd {
            if chars == "0" || event.keyCode == 29 {
                delegate?.slideViewSetRating(0)
                return
            }
            if chars == "1" || event.keyCode == 18 {
                delegate?.slideViewSetRating(1)
                return
            }
            if chars == "2" || event.keyCode == 19 {
                delegate?.slideViewSetRating(2)
                return
            }
            if chars == "3" || event.keyCode == 20 {
                delegate?.slideViewSetRating(3)
                return
            }
            if chars == "4" || event.keyCode == 21 {
                delegate?.slideViewSetRating(4)
                return
            }
            if chars == "5" || event.keyCode == 23 {
                delegate?.slideViewSetRating(5)
                return
            }
            if chars == "6" || event.keyCode == 22 {
                delegate?.slideViewSetColor(.red)
                return
            }
            if chars == "7" || event.keyCode == 26 {
                delegate?.slideViewSetColor(.yellow)
                return
            }
            if chars == "8" || event.keyCode == 28 {
                delegate?.slideViewSetColor(.green)
                return
            }
            if chars == "9" || event.keyCode == 25 {
                delegate?.slideViewSetColor(.blue)
                return
            }
        }

        // Layout-Independent Culling Hotkeys: P, X, U
        if !isCmd {
            if lower == "p" || event.keyCode == 35 {
                delegate?.slideViewSetPick(.pick)
                return
            }
            if lower == "x" || event.keyCode == 7 {
                delegate?.slideViewSetPick(.reject)
                return
            }
            if lower == "u" || event.keyCode == 32 {
                delegate?.slideViewSetPick(.unflagged)
                return
            }
        }

        // Auto-advance toggle: 'C'
        if !isCmd && (lower == "c" || event.keyCode == 8) {
            delegate?.slideViewToggleAutoAdvance()
            return
        }

        // Multi-Up Cycle: 'S' or Tab (Single ➔ 2-UP ➔ 4-UP ➔ Single)
        if !isCmd && (lower == "s" || event.keyCode == 1 || event.keyCode == 48) {
            delegate?.slideViewCycleMultiUp()
            return
        }

        // Cycle Filter: '\\'
        if chars == "\\" || event.keyCode == 42 {
            delegate?.slideViewCycleFilter()
            return
        }

        // Live RGB Histogram: 'H'
        if !isCmd && (lower == "h" || event.keyCode == 4) {
            delegate?.slideViewToggleHistogram()
            return
        }

        // Exposure Clipping Warnings: 'O'
        if !isCmd && (lower == "o" || event.keyCode == 31) {
            delegate?.slideViewToggleClipping()
            return
        }

        // Fullscreen Toggle: 'F' (when Shift is not held)
        if !isShift && !isCmd && (lower == "f" || event.keyCode == 3) {
            delegate?.slideViewToggleFullScreen()
            return
        }

        // EXIF HUD: 'I'
        if !isCmd && (lower == "i" || event.keyCode == 34) {
            delegate?.slideViewToggleExif()
            return
        }

        switch event.keyCode {
        // Space (KeyCode 49)
        case 49:
            if isZoomed { setZoom(false) }
            delegate?.slideViewRequestNext()

        // Right Arrow, Down Arrow, Page Down, 'N'
        case 124, 125, 121, 45:
            if isZoomed { setZoom(false) }
            delegate?.slideViewRequestNext()

        // Left Arrow, Up Arrow, Page Up, 'K'
        case 123, 126, 116, 40:
            if isZoomed { setZoom(false) }
            delegate?.slideViewRequestPrevious()

        // Home
        case 115:
            if isZoomed { setZoom(false) }
            delegate?.slideViewRequestFirst()

        // End
        case 119:
            if isZoomed { setZoom(false) }
            delegate?.slideViewRequestLast()

        // Delete / Backspace
        case 51, 117:
            if isZoomed { setZoom(false) }
            if isShift {
                delegate?.slideViewRequestPurgeRejects()
            } else {
                delegate?.slideViewRequestDelete()
            }

        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Non-Blocking Cursor Auto-Hide & Hover Tracking

    public override func mouseMoved(with event: NSEvent) {
        hudView.pulse()
        resetCursorTimer()

        let mousePt = convert(event.locationInWindow, from: nil)
        let slot: Int
        switch multiUpMode {
        case .single:
            slot = 1
        case .twoUp:
            let halfWidth = bounds.width / 2
            slot = (mousePt.x > halfWidth) ? 2 : 1
        case .fourUp:
            let isTop = mousePt.y >= (bounds.height / 2)
            let isRight = mousePt.x >= (bounds.width / 2)
            if isTop && !isRight { slot = 1 }
            else if isTop && isRight { slot = 2 }
            else if !isTop && !isRight { slot = 3 }
            else { slot = 4 }
        }

        if slot != hoveredSplitSlot {
            hoveredSplitSlot = slot
            for i in 0..<4 {
                splitBadges[i].isActiveSlot = (slot == i + 1)
            }
            delegate?.slideViewHoverPaneChanged(to: slot)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        cursorTimer?.invalidate()
    }

    private func resetCursorTimer() {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            Task { @MainActor in
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    deinit {
        cursorTimer?.invalidate()
    }
}
