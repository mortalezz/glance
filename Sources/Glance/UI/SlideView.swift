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
    func slideViewToggleSplitCompare()

    // 100% Zoom Action
    func slideViewRequestZoomToggle(mouseLocation: CGPoint)
    func slideViewJumpToFaceEye()

    // Phase 3: Histogram & Exposure Clipping
    func slideViewToggleHistogram()
    func slideViewToggleClipping()
    func slideViewToggleExif()

    // Phase 4: Output & Workflow Productivity
    func slideViewRequestExport()
    func slideViewRotate(direction: RotationDirection)
    func slideViewToggleSlideshow()
    func slideViewStopSlideshow()
    func slideViewAdjustSlideshowInterval(increase: Bool)
}

/// Ultra-responsive, zero-latency layer-backed NSView.
/// Supports single image full-screen display, 2-up split burst compare mode,
/// instant 100% 1:1 pixel peeping with smooth pan/drag, live RGB histogram,
/// and camera-style exposure clipping warnings ("blinkies").
@MainActor
public final class SlideView: NSView {
    public weak var delegate: SlideViewDelegate?

    private let leftContainerLayer = CALayer()
    private let leftImageLayer = CALayer()
    private let leftClippingLayer = CALayer()

    private let rightContainerLayer = CALayer()
    private let rightImageLayer = CALayer()
    private let rightClippingLayer = CALayer()

    // Aliases for compatibility
    private var containerLayer: CALayer { leftContainerLayer }
    private var imageLayer: CALayer { leftImageLayer }
    private var splitLayer: CALayer { rightImageLayer }

    public let hudView = GlassHudView()
    public let histogramHud = HistogramHudView()
    public let exifHud = ExifHudView()
    public let quickHelpView = QuickHelpView()

    public private(set) var isSplitMode: Bool = false
    public private(set) var isZoomed: Bool = false
    public private(set) var isClippingActive: Bool = false

    // Zoom & Pan state
    private var zoomPanOffset: CGPoint = .zero
    private var dragStartMouse: CGPoint = .zero
    private var dragStartOffset: CGPoint = .zero
    private var isDragging: Bool = false
    private var currentImageSize: CGSize = .zero
    private var rightImageSize: CGSize = .zero

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

        // Left Container Layer
        leftContainerLayer.backgroundColor = NSColor.black.cgColor
        leftContainerLayer.masksToBounds = true
        layer?.addSublayer(leftContainerLayer)

        // Left Image Layer
        leftImageLayer.backgroundColor = NSColor.black.cgColor
        leftImageLayer.isOpaque = true
        leftImageLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "transform": NSNull()
        ]
        leftContainerLayer.addSublayer(leftImageLayer)

        // Left Exposure Clipping Overlay Layer ("Blinkies")
        leftClippingLayer.backgroundColor = NSColor.clear.cgColor
        leftClippingLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "transform": NSNull(),
            "opacity": NSNull()
        ]
        leftClippingLayer.isHidden = true
        leftImageLayer.addSublayer(leftClippingLayer)

        // Right Container Layer (for 2-Up Split Compare)
        rightContainerLayer.backgroundColor = NSColor.black.cgColor
        rightContainerLayer.masksToBounds = true
        rightContainerLayer.isHidden = true
        layer?.addSublayer(rightContainerLayer)

        // Right Image Layer
        rightImageLayer.backgroundColor = NSColor.black.cgColor
        rightImageLayer.isOpaque = true
        rightImageLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "transform": NSNull()
        ]
        rightContainerLayer.addSublayer(rightImageLayer)

        // Right Exposure Clipping Overlay Layer
        rightClippingLayer.backgroundColor = NSColor.clear.cgColor
        rightClippingLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "transform": NSNull(),
            "opacity": NSNull()
        ]
        rightClippingLayer.isHidden = true
        rightImageLayer.addSublayer(rightClippingLayer)
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

        NSLayoutConstraint.activate([
            hudView.centerXAnchor.constraint(equalTo: centerXAnchor),
            hudView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            hudView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            hudView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            hudView.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),

            histogramHud.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            histogramHud.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            histogramHud.widthAnchor.constraint(equalToConstant: 284),

            exifHud.topAnchor.constraint(equalTo: topAnchor, constant: 28),
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

        if isSplitMode {
            let halfWidth = (bounds.width - 2) / 2
            let leftFrame = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
            let rightFrame = CGRect(x: halfWidth + 2, y: 0, width: halfWidth, height: bounds.height)

            leftContainerLayer.frame = leftFrame
            rightContainerLayer.frame = rightFrame
            rightContainerLayer.isHidden = false

            if isZoomed {
                // Synchronous 100% Pixel Peeping across BOTH split panes!
                let nativeW1 = (currentImageSize.width > 0 ? currentImageSize.width : halfWidth * scale) / scale
                let nativeH1 = (currentImageSize.height > 0 ? currentImageSize.height : bounds.height * scale) / scale

                leftImageLayer.contentsGravity = .resize
                leftImageLayer.bounds = CGRect(x: 0, y: 0, width: nativeW1, height: nativeH1)

                let rSize = rightImageSize.width > 0 ? rightImageSize : currentImageSize
                let nativeW2 = (rSize.width > 0 ? rSize.width : halfWidth * scale) / scale
                let nativeH2 = (rSize.height > 0 ? rSize.height : bounds.height * scale) / scale

                rightImageLayer.contentsGravity = .resize
                rightImageLayer.bounds = CGRect(x: 0, y: 0, width: nativeW2, height: nativeH2)

                let maxPanX1 = max(0, (nativeW1 - halfWidth) / 2)
                let maxPanY1 = max(0, (nativeH1 - bounds.height) / 2)
                let maxPanX2 = max(0, (nativeW2 - halfWidth) / 2)
                let maxPanY2 = max(0, (nativeH2 - bounds.height) / 2)

                let maxPanX = max(maxPanX1, maxPanX2)
                let maxPanY = max(maxPanY1, maxPanY2)

                zoomPanOffset.x = min(maxPanX, max(-maxPanX, zoomPanOffset.x))
                zoomPanOffset.y = min(maxPanY, max(-maxPanY, zoomPanOffset.y))

                leftImageLayer.position = CGPoint(
                    x: (halfWidth / 2) + zoomPanOffset.x,
                    y: (bounds.height / 2) + zoomPanOffset.y
                )
                rightImageLayer.position = CGPoint(
                    x: (halfWidth / 2) + zoomPanOffset.x,
                    y: (bounds.height / 2) + zoomPanOffset.y
                )
            } else {
                leftImageLayer.contentsGravity = .resizeAspect
                leftImageLayer.bounds = CGRect(origin: .zero, size: leftFrame.size)
                leftImageLayer.position = CGPoint(x: leftFrame.width / 2, y: leftFrame.height / 2)

                rightImageLayer.contentsGravity = .resizeAspect
                rightImageLayer.bounds = CGRect(origin: .zero, size: rightFrame.size)
                rightImageLayer.position = CGPoint(x: rightFrame.width / 2, y: rightFrame.height / 2)

                zoomPanOffset = .zero
            }
        } else {
            leftContainerLayer.frame = bounds
            rightContainerLayer.frame = .zero
            rightContainerLayer.isHidden = true

            if isZoomed && currentImageSize.width > 0 && currentImageSize.height > 0 {
                // Single 100% 1:1 Pixel Peep mode
                let nativeW = currentImageSize.width / scale
                let nativeH = currentImageSize.height / scale

                leftImageLayer.contentsGravity = .resize
                leftImageLayer.bounds = CGRect(x: 0, y: 0, width: nativeW, height: nativeH)

                let maxPanX = max(0, (nativeW - bounds.width) / 2)
                let maxPanY = max(0, (nativeH - bounds.height) / 2)
                zoomPanOffset.x = min(maxPanX, max(-maxPanX, zoomPanOffset.x))
                zoomPanOffset.y = min(maxPanY, max(-maxPanY, zoomPanOffset.y))

                leftImageLayer.position = CGPoint(
                    x: (bounds.width / 2) + zoomPanOffset.x,
                    y: (bounds.height / 2) + zoomPanOffset.y
                )
            } else {
                leftImageLayer.contentsGravity = .resizeAspect
                leftImageLayer.bounds = bounds
                leftImageLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
                zoomPanOffset = .zero
            }
        }

        leftClippingLayer.frame = leftImageLayer.bounds
        rightClippingLayer.frame = rightImageLayer.bounds

        CATransaction.commit()
    }

    public func displayImage(
        _ cgImage: CGImage?,
        nextImage: CGImage? = nil,
        info: HudInfo? = nil,
        nativeSize: CGSize? = nil,
        rightNativeSize: CGSize? = nil
    ) {
        if let size = nativeSize {
            currentImageSize = size
        } else if let img = cgImage {
            currentImageSize = CGSize(width: img.width, height: img.height)
        }

        if let rSize = rightNativeSize {
            rightImageSize = rSize
        } else if let rImg = nextImage {
            rightImageSize = CGSize(width: rImg.width, height: rImg.height)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftImageLayer.contents = cgImage

        if isSplitMode && nextImage != nil {
            rightImageLayer.contents = nextImage
            rightContainerLayer.isHidden = false
        } else {
            rightImageLayer.contents = nil
            rightContainerLayer.isHidden = true
        }
        CATransaction.commit()

        updateLayerLayout(animated: false)

        if let info = info {
            hudView.update(with: info)
            exifHud.update(with: info.exif, dimensions: info.dimensions, fileSize: info.fileSize)
        }
    }

    public func setSplitMode(_ enabled: Bool) {
        isSplitMode = enabled
        needsLayout = true
    }

    public func displayMessage(_ message: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        splitLayer.contents = nil
        leftClippingLayer.contents = nil
        rightClippingLayer.contents = nil
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

    public func updateHistogram(_ data: HistogramData) {
        histogramHud.update(with: data)
    }

    public func setHistogramVisible(_ visible: Bool) {
        histogramHud.setVisible(visible)
    }

    public func setExifVisible(_ visible: Bool) {
        exifHud.setVisible(visible)
    }

    public func setClippingActive(_ active: Bool) {
        isClippingActive = active
        leftClippingLayer.isHidden = !active
        rightClippingLayer.isHidden = !active

        if active {
            startBlinkyAnimation()
        } else {
            stopBlinkyAnimation()
        }
    }

    public func updateClippingMask(_ mask: CGImage?, rightMask: CGImage? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftClippingLayer.contents = mask
        rightClippingLayer.contents = rightMask
        CATransaction.commit()
    }

    private func startBlinkyAnimation() {
        leftClippingLayer.removeAnimation(forKey: "blinkyPulse")
        rightClippingLayer.removeAnimation(forKey: "blinkyPulse")

        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.20
        anim.toValue = 0.95
        anim.duration = 0.50
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        leftClippingLayer.add(anim, forKey: "blinkyPulse")
        rightClippingLayer.add(anim, forKey: "blinkyPulse")
    }

    private func stopBlinkyAnimation() {
        leftClippingLayer.removeAnimation(forKey: "blinkyPulse")
        rightClippingLayer.removeAnimation(forKey: "blinkyPulse")
    }

    // MARK: - 100% Zoom & Pan Mechanics

    public func setZoom(
        _ zoomed: Bool,
        anchorPointInView: CGPoint? = nil,
        fullResImage: CGImage? = nil,
        originalDimensions: CGSize? = nil,
        rightFullResImage: CGImage? = nil,
        rightOriginalDimensions: CGSize? = nil
    ) {
        if let dims = originalDimensions {
            currentImageSize = dims
        }
        if let fullImg = fullResImage {
            leftImageLayer.contents = fullImg
        }
        if let rDims = rightOriginalDimensions {
            rightImageSize = rDims
        }
        if let rFullImg = rightFullResImage {
            rightImageLayer.contents = rFullImg
        }

        guard isZoomed != zoomed else { return }
        isZoomed = zoomed
        hudView.updateZoomState(isZoomed)

        if isZoomed {
            // Anchor zoom around cursor location
            let mousePt = anchorPointInView ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let scale = window?.backingScaleFactor ?? 2.0

            if isSplitMode {
                // In 2-up split mode, treat mouse offset relative to whichever split pane it clicked in
                let halfWidth = (bounds.width - 2) / 2
                let paneLocalX = mousePt.x > halfWidth ? (mousePt.x - (halfWidth + 2)) : mousePt.x
                let centerOffset = CGPoint(
                    x: (halfWidth / 2) - paneLocalX,
                    y: bounds.midY - mousePt.y
                )
                let nativeW = currentImageSize.width > 0 ? (currentImageSize.width / scale) : halfWidth
                let nativeH = currentImageSize.height > 0 ? (currentImageSize.height / scale) : bounds.height

                let fitRatioX = nativeW / max(1, halfWidth)
                let fitRatioY = nativeH / max(1, bounds.height)

                zoomPanOffset = CGPoint(
                    x: centerOffset.x * fitRatioX,
                    y: centerOffset.y * fitRatioY
                )
            } else {
                let centerOffset = CGPoint(
                    x: bounds.midX - mousePt.x,
                    y: bounds.midY - mousePt.y
                )
                let nativeW = currentImageSize.width / scale
                let nativeH = currentImageSize.height / scale

                let fitRatioX = nativeW / max(1, bounds.width)
                let fitRatioY = nativeH / max(1, bounds.height)

                zoomPanOffset = CGPoint(
                    x: centerOffset.x * fitRatioX,
                    y: centerOffset.y * fitRatioY
                )
            }
        } else {
            zoomPanOffset = .zero
        }

        updateLayerLayout(animated: true)
    }

    /// Zooms into 100% 1:1 pixel peeping centered precisely on a normalized image coordinate (e.g. detected subject eye)
    public func zoomToNormalizedPoint(
        _ normPoint: CGPoint,
        fullResImage: CGImage? = nil,
        originalDimensions: CGSize? = nil,
        label: String? = nil
    ) {
        if let dims = originalDimensions {
            currentImageSize = dims
        }
        if let fullImg = fullResImage {
            leftImageLayer.contents = fullImg
        }

        isZoomed = true
        hudView.updateZoomState(true)

        let scale = window?.backingScaleFactor ?? 2.0
        if isSplitMode {
            let halfWidth = (bounds.width - 2) / 2
            let nativeW = currentImageSize.width > 0 ? (currentImageSize.width / scale) : halfWidth
            let nativeH = currentImageSize.height > 0 ? (currentImageSize.height / scale) : bounds.height
            zoomPanOffset = CGPoint(
                x: (0.5 - normPoint.x) * nativeW,
                y: (0.5 - normPoint.y) * nativeH
            )
        } else {
            let nativeW = currentImageSize.width > 0 ? (currentImageSize.width / scale) : bounds.width
            let nativeH = currentImageSize.height > 0 ? (currentImageSize.height / scale) : bounds.height
            zoomPanOffset = CGPoint(
                x: (0.5 - normPoint.x) * nativeW,
                y: (0.5 - normPoint.y) * nativeH
            )
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
        if !isZoomed {
            // Click to zoom in
            delegate?.slideViewRequestZoomToggle(mouseLocation: mousePt)
        } else {
            // Start panning
            isDragging = true
            dragStartMouse = mousePt
            dragStartOffset = zoomPanOffset
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isZoomed && isDragging else { return }
        let currentMouse = convert(event.locationInWindow, from: nil)
        let deltaX = currentMouse.x - dragStartMouse.x
        let deltaY = currentMouse.y - dragStartMouse.y

        zoomPanOffset = CGPoint(
            x: dragStartOffset.x + deltaX,
            y: dragStartOffset.y + deltaY
        )

        updateLayerLayout(animated: false)
    }

    public override func mouseUp(with event: NSEvent) {
        if isDragging {
            let currentMouse = convert(event.locationInWindow, from: nil)
            let dist = hypot(currentMouse.x - dragStartMouse.x, currentMouse.y - dragStartMouse.y)
            isDragging = false

            // If mouse didn't drag, treat as click to zoom out
            if dist < 4.0 {
                delegate?.slideViewRequestZoomToggle(mouseLocation: currentMouse)
            }
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard isZoomed else {
            super.scrollWheel(with: event)
            return
        }

        // Two-finger trackpad panning when zoomed in
        zoomPanOffset.x += event.scrollingDeltaX
        zoomPanOffset.y -= event.scrollingDeltaY
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

        // Esc (KeyCode 53) or 'Q' (KeyCode 12): Unequivocally quit Glance to reveal Finder
        if event.keyCode == 53 || lower == "q" || event.keyCode == 12 {
            delegate?.slideViewClose()
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

        // Quick Help Cheatsheet: '?' only (Shift + /)
        if chars == "?" || (event.keyCode == 44 && isShift) {
            toggleHelp()
            return
        }

        switch event.keyCode {
        // Space, Right Arrow, Down Arrow, Page Down, 'N'
        case 49, 124, 125, 121, 45:
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

        // 'Z' key handled in layout-independent section above

        // Delete / Backspace
        case 51, 117:
            if isZoomed { setZoom(false) }
            if isShift {
                delegate?.slideViewRequestPurgeRejects()
            } else {
                delegate?.slideViewRequestDelete()
            }

        // --- CULLING HOTKEYS ---
        case 35: // 'P'
            delegate?.slideViewSetPick(.pick)
        case 7:  // 'X'
            delegate?.slideViewSetPick(.reject)
        case 32: // 'U'
            delegate?.slideViewSetPick(.unflagged)
        case 8:  // 'C'
            delegate?.slideViewToggleAutoAdvance()
        case 1, 48: // 'S' or Tab
            delegate?.slideViewToggleSplitCompare()
        case 42: // '\'
            delegate?.slideViewCycleFilter()

        // --- PHASE 3: HISTOGRAM & CLIPPING HOTKEYS ---
        case 4: // 'H' -> Toggle Live RGB Histogram
            delegate?.slideViewToggleHistogram()
        case 31: // 'O' -> Toggle Exposure Clipping Warnings ("Blinkies")
            delegate?.slideViewToggleClipping()

        // Phase 4 hotkeys handled above via layout-independent matcher

        // Numbers 0..5 (Stars) & 6..9 (Colors)
        case 29:
            delegate?.slideViewSetRating(0)
        case 18:
            delegate?.slideViewSetRating(1)
        case 19:
            delegate?.slideViewSetRating(2)
        case 20:
            delegate?.slideViewSetRating(3)
        case 21:
            delegate?.slideViewSetRating(4)
        case 23:
            delegate?.slideViewSetRating(5)

        case 22: // 6 -> Red
            delegate?.slideViewSetColor(.red)
        case 26: // 7 -> Yellow
            delegate?.slideViewSetColor(.yellow)
        case 28: // 8 -> Green
            delegate?.slideViewSetColor(.green)
        case 25: // 9 -> Blue
            delegate?.slideViewSetColor(.blue)

        case 3: // 'F'
            delegate?.slideViewToggleFullScreen()
        case 34: // 'I'
            delegate?.slideViewToggleExif()
        // Note: Esc and 'Q' are handled unequivocally at the top of keyDown

        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Non-Blocking Cursor Auto-Hide

    public override func mouseMoved(with event: NSEvent) {
        hudView.pulse()
        resetCursorTimer()
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
