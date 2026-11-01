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
    func slideViewBurstKnockout()
    func slideViewSetColor(_ color: ColorLabel)
    func slideViewToggleAutoAdvance()
    func slideViewCycleFilter()
    func slideViewCycleMultiUp()
    func slideViewToggleSplitCompare()
    func slideViewHoverPaneChanged(to slot: Int)

    // Scene Leap Navigation (Same Scene & Burst Traversal)
    func slideViewRequestNextScene()
    func slideViewRequestPreviousScene()
    func slideViewRequestJumpToHero()

    // Face & Eye Inspection Overlay
    func slideViewToggleFaceOverlay()
    func slideViewJumpToFace(index: Int)

    // Targeted Batch Export & Filtering
    func slideViewRequestBatchExportPicks()
    func slideViewTogglePicksFilter()

    // 100% Zoom Action
    func slideViewRequestZoomToggle(mouseLocation: CGPoint)
    func slideViewJumpToFaceEye()

    // Phase 3: Histogram & Exposure Clipping
    func slideViewToggleHistogram()
    func slideViewToggleClipping()
    func slideViewToggleFalseColor()
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
    func slideViewJumpToFilteredPos(index: Int)
    func slideViewToggleFilmstrip()
    func slideViewToggleSlideshow()
    func slideViewStopSlideshow()
    func slideViewAdjustSlideshowInterval(increase: Bool)
}

public extension SlideViewDelegate {
    func slideViewToggleSplitCompare() {
        slideViewCycleMultiUp()
    }
    func slideViewJumpToFilteredPos(index: Int) {}
    func slideViewToggleFilmstrip() {}
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
    private let paneFalseColorLayers: [CALayer] = (0..<4).map { _ in CALayer() }

    public let hudView = GlassHudView()
    public let histogramHud = HistogramHudView()
    public let exifHud = ExifHudView()
    public let quickHelpView = QuickHelpView()
    public let topToastView = TopToastView()
    public let faceOverlayView = FaceLoupeOverlayView()
    public let cursorLoupeView = CursorLoupeView()
    public let falseColorLegendHud = FalseColorLegendHudView()
    public let filmstripHud = FilmstripHudView()

    public let splitBadges: [SplitPaneBadgeView] = (1...4).map { SplitPaneBadgeView(slot: $0) }

    private var histogramTopConstraint: NSLayoutConstraint?
    private var exifTopConstraint: NSLayoutConstraint?
    private var exifWidthConstraint: NSLayoutConstraint?

    public private(set) var multiUpMode: MultiUpMode = .single
    public var isSplitMode: Bool { multiUpMode != .single }
    public private(set) var hoveredSplitSlot: Int = 1

    // Saved overlay states when QuickHelp cheatsheet is presented
    private var savedHistogramAlpha: CGFloat = 0.0
    private var savedExifAlpha: CGFloat = 0.0
    private var savedSplitBadgesAlpha: [CGFloat] = [0.0, 0.0, 0.0, 0.0]
    public private(set) var isHelpPresented: Bool = false
    public private(set) var isZoomed: Bool = false
    public private(set) var isClippingActive: Bool = false
    public private(set) var isPeakingActive: Bool = false
    public private(set) var isFalseColorActive: Bool = false
    private var savedFalseColorLegendAlpha: CGFloat = 0.0
    private var savedFilmstripAlpha: CGFloat = 0.0

    // Zoom & Pan state across up to 4 panes
    // Loupe Pop (Option B for 4-UP) & Spring-Loaded Z
    public private(set) var activeLoupeSlot: Int = 0
    public private(set) var isZHeld: Bool = false
    private var zKeyDownTimestamp: TimeInterval = 0
    private var wasZoomedOnZKeyDown: Bool = false
    private var lastZMouseLocation: CGPoint = .zero

    // Zoom & Pan state across up to 4 panes
    private var paneImageSizes: [CGSize] = Array(repeating: .zero, count: 4)
    private var zoomPanOffsets: [CGPoint] = Array(repeating: .zero, count: 4)
    private var dragStartOffsets: [CGPoint] = Array(repeating: .zero, count: 4)
    private var dragStartMouse: CGPoint = .zero
    private var isDragging: Bool = false

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

        NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePaneBorders(animated: true)
            }
        }

        for i in 0..<4 {
            let container = paneContainerLayers[i]
            container.backgroundColor = NSColor.black.cgColor
            container.cornerCurve = .continuous
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

            let fc = paneFalseColorLayers[i]
            fc.backgroundColor = NSColor.clear.cgColor
            fc.contentsGravity = .resizeAspect
            fc.actions = [
                "contents": NSNull(),
                "bounds": NSNull(),
                "position": NSNull(),
                "transform": NSNull(),
                "opacity": NSNull()
            ]
            fc.isHidden = true
            img.addSublayer(fc)
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
        exifHud.onHoverExpansionChanged = { [weak self] isExpanded in
            guard let self = self else { return }
            self.exifWidthConstraint?.constant = isExpanded ? 370 : 284
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.layoutSubtreeIfNeeded()
            }
        }
        exifHud.onCopiedExif = { [weak self] in
            self?.showToast("EXIF Copied to Clipboard", icon: "📋", shortcut: nil, tint: .systemCyan)
        }

        quickHelpView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(quickHelpView)
        quickHelpView.onWillPresent = { [weak self] in
            self?.hideOverlaysForHelp()
        }
        quickHelpView.onWillDismiss = { [weak self] in
            self?.restoreOverlaysAfterHelp()
        }

        topToastView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topToastView)

        faceOverlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(faceOverlayView)
        faceOverlayView.onFaceSelected = { [weak self] faceIndex in
            self?.delegate?.slideViewJumpToFace(index: faceIndex)
        }
        faceOverlayView.onClose = { [weak self] in
            self?.delegate?.slideViewToggleFaceOverlay()
        }

        cursorLoupeView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(cursorLoupeView)

        falseColorLegendHud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(falseColorLegendHud)

        filmstripHud.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filmstripHud)
        filmstripHud.onSelectIndex = { [weak self] index in
            self?.delegate?.slideViewJumpToFilteredPos(index: index)
        }

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
            {
                let c = exifHud.widthAnchor.constraint(equalToConstant: 284)
                self.exifWidthConstraint = c
                return c
            }(),

            quickHelpView.centerXAnchor.constraint(equalTo: centerXAnchor),
            quickHelpView.centerYAnchor.constraint(equalTo: centerYAnchor),

            topToastView.centerXAnchor.constraint(equalTo: centerXAnchor),
            topToastView.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            topToastView.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),

            faceOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            faceOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -76),

            falseColorLegendHud.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            falseColorLegendHud.centerYAnchor.constraint(equalTo: centerYAnchor),
            falseColorLegendHud.widthAnchor.constraint(equalToConstant: 136),
            falseColorLegendHud.heightAnchor.constraint(equalToConstant: 220),

            filmstripHud.centerXAnchor.constraint(equalTo: centerXAnchor),
            filmstripHud.bottomAnchor.constraint(equalTo: hudView.topAnchor, constant: -12),
            filmstripHud.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            filmstripHud.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            filmstripHud.widthAnchor.constraint(lessThanOrEqualToConstant: 960),
            filmstripHud.heightAnchor.constraint(equalToConstant: 88)
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

            let pad: CGFloat = 6
            let gutter: CGFloat = 6
            let paneW = floor((totalW - 2 * pad - gutter) / 2)
            let paneH = totalH - 2 * pad

            let frames: [CGRect] = [
                CGRect(x: pad, y: pad, width: paneW, height: paneH),
                CGRect(x: pad + paneW + gutter, y: pad, width: paneW, height: paneH)
            ]

            let badgeW: CGFloat = min(360, max(220, paneW - 48))
            let leftBadgeX = pad + (paneW - badgeW) / 2
            let rightBadgeX = pad + paneW + gutter + (paneW - badgeW) / 2
            let badgeY = pad + paneH - 44

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            splitBadges[0].frame = CGRect(x: leftBadgeX, y: badgeY, width: badgeW, height: 34)
            splitBadges[1].frame = CGRect(x: rightBadgeX, y: badgeY, width: badgeW, height: 34)
            splitBadges[0].isHidden = (paneImageLayers[0].contents == nil)
            splitBadges[1].isHidden = (paneImageLayers[1].contents == nil)
            splitBadges[0].isActiveSlot = (hoveredSplitSlot == 1)
            splitBadges[1].isActiveSlot = (hoveredSplitSlot == 2)
            if isHelpPresented {
                splitBadges[0].alphaValue = 0.0
                splitBadges[1].alphaValue = 0.0
            }
            CATransaction.commit()

            for i in 0..<2 {
                let pFrame = frames[i]
                paneContainerLayers[i].frame = pFrame
                paneContainerLayers[i].isHidden = (paneImageLayers[i].contents == nil)

                if isZoomed {
                    let imgSize = paneImageSizes[i].width > 0 ? paneImageSizes[i] : paneImageSizes[0]
                    let nativeW = (imgSize.width > 0 ? imgSize.width : paneW * scale) / scale
                    let nativeH = (imgSize.height > 0 ? imgSize.height : paneH * scale) / scale

                    paneImageLayers[i].contentsGravity = .resize
                    paneImageLayers[i].bounds = CGRect(x: 0, y: 0, width: nativeW, height: nativeH)

                    let maxPanX = max(0, (nativeW - paneW) / 2)
                    let maxPanY = max(0, (nativeH - paneH) / 2)

                    zoomPanOffsets[i].x = min(maxPanX, max(-maxPanX, zoomPanOffsets[i].x))
                    zoomPanOffsets[i].y = min(maxPanY, max(-maxPanY, zoomPanOffsets[i].y))

                    paneImageLayers[i].position = CGPoint(
                        x: (paneW / 2) + zoomPanOffsets[i].x,
                        y: (paneH / 2) + zoomPanOffsets[i].y
                    )
                } else {
                    paneImageLayers[i].contentsGravity = .resizeAspect
                    paneImageLayers[i].bounds = CGRect(origin: .zero, size: pFrame.size)
                    paneImageLayers[i].position = CGPoint(x: pFrame.width / 2, y: pFrame.height / 2)
                    zoomPanOffsets[i] = .zero
                }
            }

        case .fourUp:
            let pad: CGFloat = 6
            let gutter: CGFloat = 6
            let paneW = floor((totalW - 2 * pad - gutter) / 2)
            let paneH = floor((totalH - 2 * pad - gutter) / 2)

            // Slot 1: TL (x: pad, y: pad + paneH + gutter)
            // Slot 2: TR (x: pad + paneW + gutter, y: pad + paneH + gutter)
            // Slot 3: BL (x: pad, y: pad)
            // Slot 4: BR (x: pad + paneW + gutter, y: pad)
            let frames: [CGRect] = [
                CGRect(x: pad, y: pad + paneH + gutter, width: paneW, height: paneH),
                CGRect(x: pad + paneW + gutter, y: pad + paneH + gutter, width: paneW, height: paneH),
                CGRect(x: pad, y: pad, width: paneW, height: paneH),
                CGRect(x: pad + paneW + gutter, y: pad, width: paneW, height: paneH)
            ]

            let badgeW: CGFloat = min(340, max(180, paneW - 36))
            let leftBadgeX = pad + (paneW - badgeW) / 2
            let rightBadgeX = pad + paneW + gutter + (paneW - badgeW) / 2
            let topBadgeY = pad + paneH + gutter + paneH - 42
            let bottomBadgeY = pad + paneH - 42

            if isZoomed {
                // Option B: Hovered quadrant pops to full-screen 100% Loupe!
                let s = activeLoupeSlot

                for i in 0..<4 {
                    if i == s {
                        paneContainerLayers[i].frame = bounds
                        paneContainerLayers[i].isHidden = (paneImageLayers[i].contents == nil)

                        let imgSize = paneImageSizes[i].width > 0 ? paneImageSizes[i] : paneImageSizes[0]
                        let nativeW = (imgSize.width > 0 ? imgSize.width : totalW * scale) / scale
                        let nativeH = (imgSize.height > 0 ? imgSize.height : totalH * scale) / scale

                        paneImageLayers[i].contentsGravity = .resize
                        paneImageLayers[i].bounds = CGRect(x: 0, y: 0, width: nativeW, height: nativeH)

                        let maxPanX = max(0, (nativeW - totalW) / 2)
                        let maxPanY = max(0, (nativeH - totalH) / 2)
                        zoomPanOffsets[i].x = min(maxPanX, max(-maxPanX, zoomPanOffsets[i].x))
                        zoomPanOffsets[i].y = min(maxPanY, max(-maxPanY, zoomPanOffsets[i].y))

                        paneImageLayers[i].position = CGPoint(
                            x: (totalW / 2) + zoomPanOffsets[i].x,
                            y: (totalH / 2) + zoomPanOffsets[i].y
                        )
                    } else {
                        paneContainerLayers[i].frame = .zero
                        paneContainerLayers[i].isHidden = true
                    }
                }

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for i in 0..<4 {
                    if i == s {
                        splitBadges[i].frame = CGRect(x: (totalW - badgeW) / 2, y: totalH - 50, width: badgeW, height: 34)
                        splitBadges[i].isHidden = (paneImageLayers[i].contents == nil)
                        splitBadges[i].isActiveSlot = true
                    } else {
                        splitBadges[i].isHidden = true
                    }
                    if isHelpPresented {
                        splitBadges[i].alphaValue = 0.0
                    }
                }
                CATransaction.commit()
            } else {
                // Normal 4-UP Floating Studio Tiles Grid
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                splitBadges[0].frame = CGRect(x: leftBadgeX, y: topBadgeY, width: badgeW, height: 32)
                splitBadges[1].frame = CGRect(x: rightBadgeX, y: topBadgeY, width: badgeW, height: 32)
                splitBadges[2].frame = CGRect(x: leftBadgeX, y: bottomBadgeY, width: badgeW, height: 32)
                splitBadges[3].frame = CGRect(x: rightBadgeX, y: bottomBadgeY, width: badgeW, height: 32)

                for i in 0..<4 {
                    splitBadges[i].isHidden = (paneImageLayers[i].contents == nil)
                    splitBadges[i].isActiveSlot = (hoveredSplitSlot == (i + 1))
                    if isHelpPresented {
                        splitBadges[i].alphaValue = 0.0
                    }
                }
                CATransaction.commit()

                for i in 0..<4 {
                    let pFrame = frames[i]
                    paneContainerLayers[i].frame = pFrame
                    paneContainerLayers[i].isHidden = (paneImageLayers[i].contents == nil)

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
            paneFalseColorLayers[i].frame = paneImageLayers[i].bounds
            paneFalseColorLayers[i].contentsGravity = paneImageLayers[i].contentsGravity
        }

        CATransaction.commit()

        updatePaneBorders(animated: animated)
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
            if isHelpPresented {
                splitBadges[i].alphaValue = 0.0
            }
        }

        if cursorLoupeView.isPresented {
            let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let localPt = convert(mouseInWindow, from: nil)
            cursorLoupeView.updatePosition(mousePt: localPt, in: self)
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

    public func updateSlotAesthetics(slot: Int, score: AestheticScoreResult?) {
        guard slot >= 1 && slot <= 4 else { return }
        splitBadges[slot - 1].updateAestheticScore(score)
    }

    public func updateAestheticScore(_ score: AestheticScoreResult?) {
        hudView.updateAestheticScore(score)
    }

    public func updateBurstBreadcrumb(_ burst: BurstBreadcrumbInfo?) {
        hudView.updateBurstBreadcrumb(burst)
    }

    public func updateSlotScene(slot: Int, description: String?, isHero: Bool = false) {
        guard slot >= 1 && slot <= 4 else { return }
        splitBadges[slot - 1].updateBurstDescription(description, isHero: isHero)
    }

    // MARK: - Metal Vibrancy Studio Framing & Active Rims

    public func updatePaneBorders(animated: Bool = true) {
        let theme = ThemeManager.shared
        let isMulti = (multiUpMode != .single) && !isZoomed

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.14)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }

        layer?.backgroundColor = isMulti ? theme.studioCanvasColor : NSColor.black.cgColor

        for i in 0..<4 {
            let container = paneContainerLayers[i]
            if isMulti && (i < multiUpMode.rawValue) && (paneImageLayers[i].contents != nil) {
                let slotNum = i + 1
                let isActive = (hoveredSplitSlot == slotNum)
                let colors = theme.slotSemanticColor(for: slotNum)

                container.cornerRadius = 10.0
                container.cornerCurve = .continuous
                container.masksToBounds = true

                if isActive {
                    container.borderWidth = 1.5
                    container.borderColor = colors.glowBorder
                    container.opacity = 1.0
                } else {
                    container.borderWidth = 0.5
                    container.borderColor = colors.restingBorder
                    container.opacity = 0.94
                }
            } else {
                container.cornerRadius = 0.0
                container.borderWidth = 0.0
                container.borderColor = nil
                container.opacity = 1.0
            }
        }

        CATransaction.commit()
    }

    public func setHoveredSplitSlot(_ slot: Int) {
        guard slot >= 1 && slot <= 4 else { return }
        hoveredSplitSlot = slot
        for i in 0..<4 {
            splitBadges[i].isActiveSlot = (slot == i + 1)
        }
        updatePaneBorders(animated: false)
    }

    public func setMultiUpMode(_ mode: MultiUpMode) {
        multiUpMode = mode
        hoveredSplitSlot = 1
        activeLoupeSlot = 0
        for i in 0..<4 {
            splitBadges[i].isActiveSlot = (i == 0)
        }
        histogramTopConstraint?.constant = (mode != .single) ? 62 : 28
        exifTopConstraint?.constant = (mode != .single) ? 62 : 28
        needsLayout = true
        updatePaneBorders(animated: false)
    }

    public func displayMessage(_ message: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<4 {
            paneImageLayers[i].contents = nil
            paneClippingLayers[i].contents = nil
            panePeakingLayers[i].contents = nil
            paneFalseColorLayers[i].contents = nil
            splitBadges[i].isHidden = true
        }
        CATransaction.commit()

        let info = HudInfo(currentIndex: 0, totalCount: 0, filename: message)
        hudView.update(with: info)
    }

    public func toggleHelp() {
        quickHelpView.toggle()
    }

    public func updateFaceTiles(_ tiles: [FaceTileData]) {
        faceOverlayView.update(with: tiles)
    }

    public func setFaceOverlayVisible(_ visible: Bool) {
        if visible {
            faceOverlayView.present()
        } else {
            faceOverlayView.dismiss()
        }
    }

    public func showToast(
        _ message: String,
        icon: String? = nil,
        shortcut: String? = nil,
        tint: NSColor? = nil,
        duration: TimeInterval = 1.6
    ) {
        topToastView.present(
            TopToastView.ToastPayload(
                message: message,
                icon: icon,
                shortcutHint: shortcut,
                tintColor: tint,
                duration: duration
            )
        )
    }

    // MARK: - Magnifier Loupe Navigation & Interaction

    public func toggleCursorLoupe() {
        if !cursorLoupeView.isPresented {
            cursorLoupeView.setMagnification(2.0)
            cursorLoupeView.present()
            let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let localPt = convert(mouseInWindow, from: nil)
            cursorLoupeView.updatePosition(mousePt: localPt, in: self)
            showToast("Loupe 2×", icon: "🔍", shortcut: "M to 4×")
        } else if cursorLoupeView.magnification == 2.0 {
            cursorLoupeView.setMagnification(4.0)
            let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let localPt = convert(mouseInWindow, from: nil)
            cursorLoupeView.updatePosition(mousePt: localPt, in: self)
            showToast("Loupe 4×", icon: "🔍", shortcut: "M to dismiss")
        } else {
            cursorLoupeView.dismiss()
            showToast("Loupe Off", icon: "🔍", shortcut: "M")
        }
    }

    public func imageInfoForPoint(_ point: CGPoint) -> (image: CGImage, imageRectInView: CGRect)? {
        let maxCount = min(4, multiUpMode.rawValue)
        for i in 0..<maxCount {
            let container = paneContainerLayers[i]
            guard !container.isHidden, container.frame.contains(point) else { continue }
            guard let raw = paneImageLayers[i].contents, CFGetTypeID(raw as CFTypeRef) == CGImage.typeID else { continue }
            let img = raw as! CGImage

            let pSize = container.bounds.size
            guard pSize.width > 0 && pSize.height > 0 else { continue }

            let rectInView: CGRect
            if isZoomed {
                let imgLayer = paneImageLayers[i]
                let originX = container.frame.minX + imgLayer.position.x - imgLayer.bounds.width / 2.0
                let originY = container.frame.minY + imgLayer.position.y - imgLayer.bounds.height / 2.0
                rectInView = CGRect(x: originX, y: originY, width: imgLayer.bounds.width, height: imgLayer.bounds.height)
            } else {
                let imgSize = CGSize(width: img.width, height: img.height)
                guard imgSize.width > 0 && imgSize.height > 0 else { continue }
                let fitScale = min(pSize.width / imgSize.width, pSize.height / imgSize.height)
                let fitW = imgSize.width * fitScale
                let fitH = imgSize.height * fitScale
                let originX = container.frame.minX + (pSize.width - fitW) / 2.0
                let originY = container.frame.minY + (pSize.height - fitH) / 2.0
                rectInView = CGRect(x: originX, y: originY, width: fitW, height: fitH)
            }
            return (img, rectInView)
        }
        return nil
    }

    private func hideOverlaysForHelp() {
        guard !isHelpPresented else { return }
        isHelpPresented = true
        topToastView.dismiss(animated: false)
        faceOverlayView.dismiss()
        cursorLoupeView.dismiss()
        savedHistogramAlpha = histogramHud.alphaValue
        savedExifAlpha = exifHud.alphaValue
        savedFalseColorLegendAlpha = falseColorLegendHud.alphaValue
        savedFilmstripAlpha = filmstripHud.alphaValue
        for i in 0..<4 {
            savedSplitBadgesAlpha[i] = splitBadges[i].alphaValue
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            self.histogramHud.animator().alphaValue = 0.0
            self.exifHud.animator().alphaValue = 0.0
            self.falseColorLegendHud.animator().alphaValue = 0.0
            self.filmstripHud.animator().alphaValue = 0.0
            for badge in self.splitBadges {
                badge.animator().alphaValue = 0.0
            }
        }
    }

    private func restoreOverlaysAfterHelp() {
        guard isHelpPresented else { return }
        isHelpPresented = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            self.histogramHud.animator().alphaValue = self.savedHistogramAlpha
            self.exifHud.animator().alphaValue = self.savedExifAlpha
            self.falseColorLegendHud.animator().alphaValue = self.savedFalseColorLegendAlpha
            self.filmstripHud.animator().alphaValue = self.savedFilmstripAlpha
            for i in 0..<4 {
                if self.multiUpMode != .single && self.paneImageLayers[i].contents != nil {
                    self.splitBadges[i].animator().alphaValue = (self.savedSplitBadgesAlpha[i] > 0) ? self.savedSplitBadgesAlpha[i] : 1.0
                }
            }
        }
    }

    public func updateSplitPaneInfo(slot: Int, info: SplitPaneInfo?) {
        guard slot >= 1 && slot <= 4 else { return }
        splitBadges[slot - 1].update(with: info)
        if isHelpPresented {
            splitBadges[slot - 1].alphaValue = 0.0
        }
    }

    // MARK: - Phase 3: Histogram & Clipping Warnings ("Blinkies")

    public func updateHistogram(_ data: HistogramData, slot: Int? = nil) {
        histogramHud.update(with: data, slot: slot)
    }

    public func setHistogramVisible(_ visible: Bool) {
        if isHelpPresented {
            savedHistogramAlpha = visible ? 1.0 : 0.0
            histogramHud.setVisible(false, animated: false)
        } else {
            histogramHud.setVisible(visible)
        }
    }

    public func setExifVisible(_ visible: Bool) {
        if isHelpPresented {
            savedExifAlpha = visible ? 1.0 : 0.0
            exifHud.setVisible(false, animated: false)
        } else {
            exifHud.setVisible(visible)
        }
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

    public func setFalseColorActive(_ active: Bool) {
        isFalseColorActive = active
        for i in 0..<4 {
            paneFalseColorLayers[i].isHidden = !active
        }
        if active {
            falseColorLegendHud.showLegend()
        } else {
            falseColorLegendHud.hideLegend()
        }
    }

    public func updateFalseColorMasks(_ masks: [CGImage?]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<4 {
            paneFalseColorLayers[i].contents = (i < masks.count) ? masks[i] : nil
        }
        CATransaction.commit()
    }

    public func updatePeakingMasks(_ masks: [CGImage?]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<4 {
            panePeakingLayers[i].contents = (i < masks.count) ? masks[i] : nil
        }
        CATransaction.commit()
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
        targetPaneIndex: Int? = nil,
        fullResImage: CGImage? = nil,
        originalDimensions: CGSize? = nil,
        rightFullResImage: CGImage? = nil,
        rightOriginalDimensions: CGSize? = nil,
        multiFullResImages: [CGImage?] = [],
        multiOriginalDimensions: [CGSize] = []
    ) {
        if let target = targetPaneIndex {
            activeLoupeSlot = max(0, min(3, target))
        } else if multiUpMode == .fourUp {
            activeLoupeSlot = max(0, min(3, hoveredSplitSlot - 1))
        }

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

            switch multiUpMode {
            case .single:
                let nativeW = (paneImageSizes[0].width > 0 ? paneImageSizes[0].width : totalW * scale) / scale
                let nativeH = (paneImageSizes[0].height > 0 ? paneImageSizes[0].height : totalH * scale) / scale
                let normPt = imageNormalizedPoint(fromPaneLocalPoint: mousePt, paneSize: bounds.size, imageSize: paneImageSizes[0])
                zoomPanOffsets[0] = CGPoint(
                    x: (0.5 - normPt.x) * nativeW,
                    y: (0.5 - normPt.y) * nativeH
                )

            case .twoUp:
                let pad: CGFloat = 6
                let gutter: CGFloat = 6
                let paneW = floor((totalW - 2 * pad - gutter) / 2)
                let paneH = totalH - 2 * pad
                let clickedPaneIndex = (mousePt.x > (totalW / 2)) ? 1 : 0
                let clickedPaneFrame = (clickedPaneIndex == 1)
                    ? CGRect(x: pad + paneW + gutter, y: pad, width: paneW, height: paneH)
                    : CGRect(x: pad, y: pad, width: paneW, height: paneH)

                let paneLocalPt = CGPoint(x: mousePt.x - clickedPaneFrame.minX, y: mousePt.y - clickedPaneFrame.minY)
                let clickedImgSize = paneImageSizes[clickedPaneIndex].width > 0 ? paneImageSizes[clickedPaneIndex] : paneImageSizes[0]
                let normPt = imageNormalizedPoint(fromPaneLocalPoint: paneLocalPt, paneSize: clickedPaneFrame.size, imageSize: clickedImgSize)

                for i in 0..<2 {
                    let imgSize = paneImageSizes[i].width > 0 ? paneImageSizes[i] : clickedImgSize
                    let nativeW = (imgSize.width > 0 ? imgSize.width : paneW * scale) / scale
                    let nativeH = (imgSize.height > 0 ? imgSize.height : paneH * scale) / scale
                    zoomPanOffsets[i] = CGPoint(
                        x: (0.5 - normPt.x) * nativeW,
                        y: (0.5 - normPt.y) * nativeH
                    )
                }

            case .fourUp:
                // Option B: Hovered quadrant pops to 100% full screen
                let pad: CGFloat = 6
                let gutter: CGFloat = 6
                let paneW = floor((totalW - 2 * pad - gutter) / 2)
                let paneH = floor((totalH - 2 * pad - gutter) / 2)
                let quadFrames: [CGRect] = [
                    CGRect(x: pad, y: pad + paneH + gutter, width: paneW, height: paneH),
                    CGRect(x: pad + paneW + gutter, y: pad + paneH + gutter, width: paneW, height: paneH),
                    CGRect(x: pad, y: pad, width: paneW, height: paneH),
                    CGRect(x: pad + paneW + gutter, y: pad, width: paneW, height: paneH)
                ]
                let s = activeLoupeSlot
                let qFrame = quadFrames[s]
                let paneLocalPt = CGPoint(x: mousePt.x - qFrame.minX, y: mousePt.y - qFrame.minY)
                let imgSize = paneImageSizes[s].width > 0 ? paneImageSizes[s] : paneImageSizes[0]
                let normPt = imageNormalizedPoint(fromPaneLocalPoint: paneLocalPt, paneSize: qFrame.size, imageSize: imgSize)

                let nativeW = (imgSize.width > 0 ? imgSize.width : totalW * scale) / scale
                let nativeH = (imgSize.height > 0 ? imgSize.height : totalH * scale) / scale

                zoomPanOffsets[s] = CGPoint(
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
        targetPaneIndex: Int? = nil,
        rightNormPoint: CGPoint? = nil,
        fullResImage: CGImage? = nil,
        originalDimensions: CGSize? = nil,
        rightFullResImage: CGImage? = nil,
        rightOriginalDimensions: CGSize? = nil,
        label: String? = nil
    ) {
        let targetSlot = targetPaneIndex ?? (multiUpMode == .fourUp ? max(0, min(3, hoveredSplitSlot - 1)) : 0)
        activeLoupeSlot = targetSlot

        if let dims = originalDimensions {
            paneImageSizes[targetSlot] = dims
        }
        if let fullImg = fullResImage {
            paneImageLayers[targetSlot].contents = fullImg
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
        } else if multiUpMode == .twoUp {
            let halfWidth = floor((totalW - 2) / 2)
            for i in 0..<2 {
                let pt = (i == 1 && rightNormPoint != nil) ? rightNormPoint! : normPoint
                let imgSize = paneImageSizes[i].width > 0 ? paneImageSizes[i] : paneImageSizes[0]
                let nativeW = imgSize.width > 0 ? (imgSize.width / scale) : halfWidth
                let nativeH = imgSize.height > 0 ? (imgSize.height / scale) : totalH
                zoomPanOffsets[i] = CGPoint(
                    x: (0.5 - pt.x) * nativeW,
                    y: (0.5 - pt.y) * nativeH
                )
            }
        } else {
            // fourUp Option B: Solo full-screen loupe for targetSlot
            let s = activeLoupeSlot
            let imgSize = paneImageSizes[s].width > 0 ? paneImageSizes[s] : paneImageSizes[0]
            let nativeW = imgSize.width > 0 ? (imgSize.width / scale) : totalW
            let nativeH = imgSize.height > 0 ? (imgSize.height / scale) : totalH
            zoomPanOffsets[s] = CGPoint(
                x: (0.5 - normPoint.x) * nativeW,
                y: (0.5 - normPoint.y) * nativeH
            )
        }

        updateLayerLayout(animated: true)

        if let msg = label {
            showToast(msg, icon: "👁️", shortcut: "⇧Z")
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

        if filmstripHud.isPresented {
            let mouseInStrip = filmstripHud.convert(event.locationInWindow, from: nil)
            if filmstripHud.bounds.contains(mouseInStrip) {
                return
            }
        }

        if hudView.alphaValue > 0.0 {
            let mouseInHud = hudView.convert(event.locationInWindow, from: nil)
            if hudView.handleMouseDown(at: mouseInHud) {
                return
            }
        }

        let mousePt = convert(event.locationInWindow, from: nil)

        // Focus slot under cursor if not already zoomed
        if !isZoomed {
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

            // Ignore clicks on empty slots in scene-aligned multi-up mode
            if paneImageLayers[clickedSlot - 1].contents == nil {
                return
            }

            if clickedSlot != hoveredSplitSlot {
                hoveredSplitSlot = clickedSlot
                for i in 0..<4 {
                    splitBadges[i].isActiveSlot = (clickedSlot == i + 1)
                }
                if multiUpMode != .single {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                }
                updatePaneBorders(animated: true)
                delegate?.slideViewHoverPaneChanged(to: clickedSlot)
            }
            activeLoupeSlot = clickedSlot - 1
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

        if multiUpMode == .fourUp {
            let s = activeLoupeSlot
            zoomPanOffsets[s] = CGPoint(
                x: dragStartOffsets[s].x + deltaX,
                y: dragStartOffsets[s].y + deltaY
            )
        } else {
            for i in 0..<4 {
                zoomPanOffsets[i] = CGPoint(
                    x: dragStartOffsets[i].x + deltaX,
                    y: dragStartOffsets[i].y + deltaY
                )
            }
        }

        updateLayerLayout(animated: false)
    }

    public override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            let currentMouse = convert(event.locationInWindow, from: nil)
            let dist = hypot(currentMouse.x - dragStartMouse.x, currentMouse.y - dragStartMouse.y)
            if dist < 4.0 {
                // Click while zoomed without drag toggles zoom back off!
                delegate?.slideViewRequestZoomToggle(mouseLocation: currentMouse)
            }
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        if filmstripHud.isPresented {
            let mousePt = convert(event.locationInWindow, from: nil)
            if filmstripHud.frame.contains(mousePt) {
                filmstripHud.handleScrollWheel(with: event)
                return
            }
        }

        if cursorLoupeView.isPresented {
            let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            if abs(delta) > 1.2 {
                if delta > 0 {
                    cursorLoupeView.setMagnification(4.0)
                } else {
                    cursorLoupeView.setMagnification(2.0)
                }
                let mousePt = convert(event.locationInWindow, from: nil)
                cursorLoupeView.updatePosition(mousePt: mousePt, in: self)
                showToast("Loupe \(Int(cursorLoupeView.magnification))×", icon: "🔍", shortcut: "Scroll")
                return
            }
        }

        guard isZoomed else {
            super.scrollWheel(with: event)
            return
        }

        // Two-finger trackpad panning when zoomed in
        if multiUpMode == .fourUp {
            let s = activeLoupeSlot
            zoomPanOffsets[s].x += event.scrollingDeltaX
            zoomPanOffsets[s].y -= event.scrollingDeltaY
        } else {
            for i in 0..<4 {
                zoomPanOffsets[i].x += event.scrollingDeltaX
                zoomPanOffsets[i].y -= event.scrollingDeltaY
            }
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

        // Cheatsheet Overlay active: Esc compacts extended mode or dismisses compact mode
        if quickHelpView.alphaValue > 0.0 {
            if event.keyCode == 53 {
                if quickHelpView.isExpanded {
                    quickHelpView.collapse()
                } else {
                    quickHelpView.dismiss()
                }
                return
            }
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

        // Esc closes Face Inspection Overlay if open
        if faceOverlayView.isPresented {
            faceOverlayView.dismiss()
            return
        }

        // Esc closes Magnifier Loupe if open
        if cursorLoupeView.isPresented && event.keyCode == 53 {
            cursorLoupeView.dismiss()
            return
        }

        // Magnifier Loupe Magnification Stepping: 2 / 4, + / -, [ / ]
        if cursorLoupeView.isPresented {
            if chars == "4" {
                cursorLoupeView.setMagnification(4.0)
                let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: bounds.midX, y: bounds.midY)
                let localPt = convert(mouseInWindow, from: nil)
                cursorLoupeView.updatePosition(mousePt: localPt, in: self)
                showToast("Loupe 4×", icon: "🔍", shortcut: "4")
                return
            }
            if chars == "2" {
                cursorLoupeView.setMagnification(2.0)
                let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: bounds.midX, y: bounds.midY)
                let localPt = convert(mouseInWindow, from: nil)
                cursorLoupeView.updatePosition(mousePt: localPt, in: self)
                showToast("Loupe 2×", icon: "🔍", shortcut: "2")
                return
            }
            if chars == "+" || chars == "=" || chars == "]" || event.keyCode == 24 || event.keyCode == 30 || event.keyCode == 69 {
                cursorLoupeView.setMagnification(4.0)
                let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: bounds.midX, y: bounds.midY)
                let localPt = convert(mouseInWindow, from: nil)
                cursorLoupeView.updatePosition(mousePt: localPt, in: self)
                showToast("Loupe 4×", icon: "🔍", shortcut: "+ / ]")
                return
            }
            if chars == "-" || chars == "_" || chars == "[" || event.keyCode == 27 || event.keyCode == 33 || event.keyCode == 78 {
                cursorLoupeView.setMagnification(2.0)
                let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: bounds.midX, y: bounds.midY)
                let localPt = convert(mouseInWindow, from: nil)
                cursorLoupeView.updatePosition(mousePt: localPt, in: self)
                showToast("Loupe 2×", icon: "🔍", shortcut: "- / [")
                return
            }
        }

        // Esc closes Filmstrip Scrubber if pinned
        if filmstripHud.isPresented && filmstripHud.isPinned && event.keyCode == 53 {
            filmstripHud.dismiss(animated: true)
            return
        }

        // Esc (KeyCode 53): If zoomed, exit zoom to grid/fit; otherwise quit Glance
        if event.keyCode == 53 {
            if isZoomed {
                delegate?.slideViewRequestZoomToggle(mouseLocation: .zero)
                return
            }
            delegate?.slideViewClose()
            return
        }

        // 'Q' (KeyCode 12): Unequivocally quit Glance to reveal Finder
        if lower == "q" || event.keyCode == 12 {
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

        // Scene Leap Navigation: ']' or Cmd+Right/Down or Opt+Right/Down
        if chars == "]" || event.keyCode == 30 || (isCmd && (event.keyCode == 124 || event.keyCode == 125)) || (event.modifierFlags.contains(.option) && (event.keyCode == 124 || event.keyCode == 125)) {
            if isZoomed { setZoom(false) }
            delegate?.slideViewStopSlideshow()
            delegate?.slideViewRequestNextScene()
            return
        }

        // Scene Leap Navigation: '[' or Cmd+Left/Up or Opt+Left/Up
        if chars == "[" || event.keyCode == 33 || (isCmd && (event.keyCode == 123 || event.keyCode == 126)) || (event.modifierFlags.contains(.option) && (event.keyCode == 123 || event.keyCode == 126)) {
            if isZoomed { setZoom(false) }
            delegate?.slideViewStopSlideshow()
            delegate?.slideViewRequestPreviousScene()
            return
        }

        // --- Layout-Independent Primary Hotkeys ---
        // Face & Eye Focus Inspection Overlay: 'A' (KeyCode 0)
        if !isCmd && !isShift && (lower == "a" || event.keyCode == 0) {
            delegate?.slideViewToggleFaceOverlay()
            return
        }

        // Rotate Right 90°: 'R' (KeyCode 15)
        if lower == "r" || event.keyCode == 15 {
            delegate?.slideViewStopSlideshow()
            delegate?.slideViewRotate(direction: .clockwise)
            return
        }

        // Rotate Left 90°: 'L' (KeyCode 37)
        if lower == "l" || event.keyCode == 37 {
            delegate?.slideViewStopSlideshow()
            delegate?.slideViewRotate(direction: .counterClockwise)
            return
        }

        // Quick Export: 'E' (⇧E: Batch Export Picks to ./Selects)
        if lower == "e" || event.keyCode == 14 {
            delegate?.slideViewStopSlideshow()
            if isShift {
                delegate?.slideViewRequestBatchExportPicks()
            } else {
                delegate?.slideViewRequestExport()
            }
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
            if event.isARepeat { return }

            zKeyDownTimestamp = ProcessInfo.processInfo.systemUptime
            wasZoomedOnZKeyDown = isZoomed
            isZHeld = true

            let mouseInWindow = window?.mouseLocationOutsideOfEventStream ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let localPt = convert(mouseInWindow, from: nil)
            lastZMouseLocation = localPt

            if isShift {
                delegate?.slideViewJumpToFaceEye()
            } else {
                let now = zKeyDownTimestamp
                if now - lastZPressTime < 0.35 {
                    delegate?.slideViewJumpToFaceEye()
                } else if !isZoomed {
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

        // Split-Screen Magnifier Loupe: 'M' (KeyCode 46)
        if !isCmd && (lower == "m" || event.keyCode == 46) {
            toggleCursorLoupe()
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

        // Layout-Independent Culling Hotkeys: P, X, U (⇧P = Burst Knockout)
        if !isCmd {
            if lower == "p" || event.keyCode == 35 {
                if isShift {
                    delegate?.slideViewBurstKnockout()
                } else {
                    delegate?.slideViewSetPick(.pick)
                }
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

        // Burst Hero Leap: 'B' (KeyCode 11)
        if !isCmd && (lower == "b" || event.keyCode == 11) {
            delegate?.slideViewStopSlideshow()
            delegate?.slideViewRequestJumpToHero()
            return
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
            if isShift {
                delegate?.slideViewTogglePicksFilter()
            } else {
                delegate?.slideViewCycleFilter()
            }
            return
        }

        // Live RGB Histogram: 'H'
        if !isCmd && (lower == "h" || event.keyCode == 4) {
            delegate?.slideViewToggleHistogram()
            return
        }

        // Exposure Warnings: 'O' (Clipping) vs '⇧O' (ARRI False Color)
        if !isCmd && (lower == "o" || event.keyCode == 31) {
            if isShift {
                delegate?.slideViewToggleFalseColor()
            } else {
                delegate?.slideViewToggleClipping()
            }
            return
        }

        // Filmstrip Scrubber: 'G' (KeyCode 5)
        if !isCmd && (lower == "g" || event.keyCode == 5) {
            toggleFilmstrip()
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

    public override func keyUp(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        let lower = chars.lowercased()

        if lower == "z" || event.keyCode == 6 {
            let holdDuration = ProcessInfo.processInfo.systemUptime - zKeyDownTimestamp
            isZHeld = false

            if wasZoomedOnZKeyDown {
                if isZoomed {
                    delegate?.slideViewRequestZoomToggle(mouseLocation: lastZMouseLocation)
                }
            } else if holdDuration > 0.25 {
                if isZoomed {
                    delegate?.slideViewRequestZoomToggle(mouseLocation: lastZMouseLocation)
                }
            }
            return
        }

        super.keyUp(with: event)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        hudView.pulse()
        resetCursorTimer()

        let mousePt = convert(event.locationInWindow, from: nil)

        if filmstripHud.isPresented {
            if filmstripHud.frame.insetBy(dx: -20, dy: -20).contains(mousePt) {
                filmstripHud.cancelAutoDismiss()
            } else if mousePt.y > filmstripHud.frame.maxY + 40 {
                filmstripHud.handleMouseExited()
            }
        } else if mousePt.y <= 36 && bounds.width > 200 {
            filmstripHud.pulseFromHover()
        }

        if cursorLoupeView.isPresented {
            CursorLoupeView.hideSystemCursor()
            cursorLoupeView.updatePosition(mousePt: mousePt, in: self)
        }

        // Hold-Z real-time mouse panning: if user holds Z and glides mouse without clicking
        if isZHeld && isZoomed {
            let deltaX = mousePt.x - lastZMouseLocation.x
            let deltaY = mousePt.y - lastZMouseLocation.y
            lastZMouseLocation = mousePt

            if multiUpMode == .fourUp {
                let s = activeLoupeSlot
                zoomPanOffsets[s].x += deltaX
                zoomPanOffsets[s].y += deltaY
            } else {
                for i in 0..<4 {
                    zoomPanOffsets[i].x += deltaX
                    zoomPanOffsets[i].y += deltaY
                }
            }
            updateLayerLayout(animated: false)
            return
        }
        lastZMouseLocation = mousePt

        guard !isZoomed else { return }

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

        // Ignore hover on empty slots in scene-aligned multi-up mode
        if paneImageLayers[slot - 1].contents == nil {
            return
        }

        if slot != hoveredSplitSlot {
            hoveredSplitSlot = slot
            for i in 0..<4 {
                splitBadges[i].isActiveSlot = (slot == i + 1)
            }
            if multiUpMode != .single {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            }
            updatePaneBorders(animated: true)
            delegate?.slideViewHoverPaneChanged(to: slot)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        cursorTimer?.invalidate()
        if cursorLoupeView.isPresented {
            CursorLoupeView.unhideSystemCursor()
        }
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

// MARK: - Filmstrip Scrubber Integration

public extension SlideView {
    func updateFilmstrip(
        items: [SlideItem],
        currentIndex: Int,
        cullingData: [String: CullingMetadata],
        burstCache: [Int: BurstBreadcrumbInfo?]
    ) {
        filmstripHud.update(
            items: items,
            currentIndex: currentIndex,
            cullingData: cullingData,
            burstCache: burstCache
        )
    }

    func updateFilmstripActiveIndex(_ newIndex: Int) {
        filmstripHud.updateActiveIndex(newIndex)
    }

    func updateFilmstripCulling(for itemId: String, metadata: CullingMetadata) {
        filmstripHud.updateCulling(for: itemId, metadata: metadata)
    }

    func updateFilmstripBurstCache(_ burstCache: [Int: BurstBreadcrumbInfo?]) {
        filmstripHud.updateBurstCache(burstCache)
    }

    func toggleFilmstrip() {
        filmstripHud.togglePinned()
        let isNowPinned = filmstripHud.isPinned && filmstripHud.isPresented
        showToast(isNowPinned ? "Filmstrip ON" : "Filmstrip OFF", icon: "🎞️", shortcut: "G")
    }
}
