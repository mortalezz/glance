import AppKit
import CoreGraphics
import QuartzCore

/// Floating circular optical magnifier loupe (2× / 4×) hovering smoothly over the cursor
/// with precision lens barrel chamfering, etched viewfinder reticle, and detached floating multiplier badge.
@MainActor
public final class CursorLoupeView: NSView {
    private static var isSystemCursorHidden = false

    public static func hideSystemCursor() {
        guard !isSystemCursorHidden else { return }
        isSystemCursorHidden = true
        NSCursor.hide()
    }

    public static func unhideSystemCursor() {
        guard isSystemCursorHidden else { return }
        isSystemCursorHidden = false
        NSCursor.unhide()
    }

    public private(set) var isPresented: Bool = false
    public private(set) var magnification: CGFloat = 2.0 // 2.0 or 4.0

    // Geometry: 226pt total barrel diameter, 210pt clear optical glass aperture (8pt machined bezel)
    private let totalDiameter: CGFloat = 226.0
    private let glassDiameter: CGFloat = 210.0
    private let bezelWidth: CGFloat = 8.0

    // Floating Multiplier Badge clearance: 8pt air gap between barrel ring and badge
    private let badgeHeight: CGFloat = 20.0
    private let badgeGap: CGFloat = 8.0
    private var barrelOffsetY: CGFloat { badgeGap + badgeHeight } // 28.0pt
    private var totalHeight: CGFloat { totalDiameter + barrelOffsetY } // 254.0pt

    // Layer Tree
    private let barrelContainer = CALayer()
    private let outerChamferLayer = CALayer()
    private let innerChamferLayer = CALayer()
    private let bezelEngravingsLayer = CAShapeLayer()

    private let glassContainer = NSView()
    private let magnifiedLayer = CALayer()
    private let opticalVignetteLayer = CAGradientLayer()
    private let lensCoatingRingLayer = CAShapeLayer()
    private let reticleLayer = CAShapeLayer()

    // Integrated Lens Barrel Dial Pill (Detached satellite badge)
    private let badgeView = NSVisualEffectView()
    private let badgeDot = CALayer()
    private let badgeLabel = NSTextField(labelWithString: "2×")

    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 226.0, height: 254.0))
        setupUI()
        setupThemeObserver()
    }

    public required init?(coder: NSCoder) {
        nil
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // 1. Check barrel circle
        let barrelCenter = CGPoint(x: totalDiameter / 2.0, y: barrelOffsetY + totalDiameter / 2.0)
        let dist = hypot(point.x - barrelCenter.x, point.y - barrelCenter.y)
        if dist <= totalDiameter / 2.0 {
            return self
        }
        // 2. Check detached badge pill
        if badgeView.frame.insetBy(dx: -4, dy: -4).contains(point) {
            return self
        }
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        cycleMagnification()
        if let slideView = superview as? SlideView {
            let mousePt = slideView.convert(event.locationInWindow, from: nil)
            updatePosition(mousePt: mousePt, in: slideView)
            slideView.showToast("Loupe \(Int(magnification))×", icon: "🔍", shortcut: "Click / M")
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if let slideView = superview as? SlideView {
            let mousePt = slideView.convert(event.locationInWindow, from: nil)
            updatePosition(mousePt: mousePt, in: slideView)
        }
    }

    private func setupUI() {
        wantsLayer = true
        isHidden = true
        alphaValue = 0.0

        // 1. Natural floating elevation drop shadow
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.48)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        self.shadow = shadow

        // 2. Machined Lens Barrel Frame (positioned at barrelOffsetY above badge)
        barrelContainer.frame = CGRect(x: 0, y: barrelOffsetY, width: totalDiameter, height: totalDiameter)
        barrelContainer.cornerRadius = totalDiameter / 2.0
        barrelContainer.cornerCurve = .circular
        barrelContainer.masksToBounds = true
        layer?.addSublayer(barrelContainer)

        // Outer chamfer line
        outerChamferLayer.frame = CGRect(x: 0, y: 0, width: totalDiameter, height: totalDiameter)
        outerChamferLayer.cornerRadius = totalDiameter / 2.0
        outerChamferLayer.cornerCurve = .circular
        outerChamferLayer.borderWidth = 1.0
        outerChamferLayer.actions = ["borderColor": NSNull()]
        barrelContainer.addSublayer(outerChamferLayer)

        // Inner diamond-cut specular ring
        innerChamferLayer.frame = CGRect(
            x: bezelWidth - 1.0,
            y: bezelWidth - 1.0,
            width: glassDiameter + 2.0,
            height: glassDiameter + 2.0
        )
        innerChamferLayer.cornerRadius = (glassDiameter + 2.0) / 2.0
        innerChamferLayer.cornerCurve = .circular
        innerChamferLayer.borderWidth = 1.0
        innerChamferLayer.actions = ["borderColor": NSNull()]
        barrelContainer.addSublayer(innerChamferLayer)

        // Micro-engravings on metal bezel (cardinal & vernier hash marks)
        bezelEngravingsLayer.frame = CGRect(x: 0, y: 0, width: totalDiameter, height: totalDiameter)
        bezelEngravingsLayer.actions = ["strokeColor": NSNull()]
        drawBezelEngravings()
        barrelContainer.addSublayer(bezelEngravingsLayer)

        // 3. Circular Glass Aperture Container
        glassContainer.wantsLayer = true
        glassContainer.frame = NSRect(
            x: bezelWidth,
            y: barrelOffsetY + bezelWidth,
            width: glassDiameter,
            height: glassDiameter
        )
        if let cl = glassContainer.layer {
            cl.cornerRadius = glassDiameter / 2.0
            cl.cornerCurve = .circular
            cl.masksToBounds = true
            cl.backgroundColor = NSColor.black.cgColor
        }
        addSubview(glassContainer)

        // Magnified Image Layer (Metal hardware-accelerated sampling via contentsRect)
        magnifiedLayer.frame = CGRect(x: 0, y: 0, width: glassDiameter, height: glassDiameter)
        magnifiedLayer.contentsGravity = .resize
        magnifiedLayer.minificationFilter = .trilinear
        magnifiedLayer.magnificationFilter = .linear
        magnifiedLayer.actions = [
            "contents": NSNull(),
            "contentsRect": NSNull(),
            "position": NSNull(),
            "bounds": NSNull()
        ]
        glassContainer.layer?.addSublayer(magnifiedLayer)

        // Optical Radial Falloff (Perimeter glass edge vignette)
        opticalVignetteLayer.frame = CGRect(x: 0, y: 0, width: glassDiameter, height: glassDiameter)
        opticalVignetteLayer.type = .radial
        opticalVignetteLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        opticalVignetteLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        opticalVignetteLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.24).cgColor
        ]
        opticalVignetteLayer.locations = [0.0, 0.72, 1.0]
        glassContainer.layer?.addSublayer(opticalVignetteLayer)

        // Anti-reflective coating perimeter ring (faint sapphire glass reflection)
        lensCoatingRingLayer.frame = CGRect(x: 0, y: 0, width: glassDiameter, height: glassDiameter)
        let coatingPath = CGMutablePath()
        coatingPath.addEllipse(in: CGRect(x: 1.0, y: 1.0, width: glassDiameter - 2.0, height: glassDiameter - 2.0))
        lensCoatingRingLayer.path = coatingPath
        lensCoatingRingLayer.fillColor = nil
        lensCoatingRingLayer.lineWidth = 1.0
        lensCoatingRingLayer.strokeColor = NSColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 0.18).cgColor
        glassContainer.layer?.addSublayer(lensCoatingRingLayer)

        // Precision Etched Reticle
        reticleLayer.frame = CGRect(x: 0, y: 0, width: glassDiameter, height: glassDiameter)
        drawPrecisionReticle()
        glassContainer.layer?.addSublayer(reticleLayer)

        // 4. Detached Floating Multiplier Badge Pill (8pt below barrel ring, perfectly rounded capsule)
        badgeView.material = .hudWindow
        badgeView.blendingMode = .withinWindow
        badgeView.state = .active
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = badgeHeight / 2.0 // 10.0pt capsule
        badgeView.layer?.cornerCurve = .continuous
        badgeView.layer?.borderWidth = 0.5
        badgeView.layer?.masksToBounds = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false

        badgeDot.frame = CGRect(x: 8.5, y: 7.0, width: 6, height: 6)
        badgeDot.cornerRadius = 3.0
        badgeDot.backgroundColor = NSColor(white: 0.85, alpha: 0.95).cgColor
        badgeView.layer?.addSublayer(badgeDot)

        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        badgeLabel.alignment = .center
        badgeLabel.textColor = .white
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeView.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.topAnchor.constraint(equalTo: badgeView.topAnchor, constant: 2.5),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: -2.5),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 19),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -8)
        ])

        addSubview(badgeView)
        NSLayoutConstraint.activate([
            badgeView.centerXAnchor.constraint(equalTo: centerXAnchor),
            badgeView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
            badgeView.heightAnchor.constraint(equalToConstant: badgeHeight)
        ])

        updateTheme()
    }

    private func drawBezelEngravings() {
        let center = totalDiameter / 2.0
        let rOuter = totalDiameter / 2.0 - 1.5
        let rInnerMajor = rOuter - 5.0
        let rInnerMinor = rOuter - 2.5

        let path = CGMutablePath()

        // 12 precision hash notches around the metal ring (every 30°)
        for i in 0..<12 {
            let angle = CGFloat(i) * (.pi / 6.0)
            let cosA = cos(angle)
            let sinA = sin(angle)
            let isMajor = (i % 3 == 0) // Cardinal 0°, 90°, 180°, 270°
            let rIn = isMajor ? rInnerMajor : rInnerMinor

            path.move(to: CGPoint(x: center + rIn * cosA, y: center + rIn * sinA))
            path.addLine(to: CGPoint(x: center + rOuter * cosA, y: center + rOuter * sinA))
        }

        bezelEngravingsLayer.path = path
        bezelEngravingsLayer.lineWidth = 1.0
        bezelEngravingsLayer.lineCap = .round
        bezelEngravingsLayer.fillColor = nil
    }

    private func drawPrecisionReticle() {
        let midX = glassDiameter / 2.0
        let midY = glassDiameter / 2.0

        let path = CGMutablePath()

        // 1. Center precision target circle (radius 14pt, diameter 28pt)
        path.addEllipse(in: CGRect(x: midX - 14.0, y: midY - 14.0, width: 28.0, height: 28.0))

        // 2. Cardinal guide hairlines with 6pt center clearance for unobstructed target inspection
        let innerClear: CGFloat = 6.0
        let outerLen: CGFloat = 36.0

        // North
        path.move(to: CGPoint(x: midX, y: midY + innerClear))
        path.addLine(to: CGPoint(x: midX, y: midY + outerLen))
        // South
        path.move(to: CGPoint(x: midX, y: midY - innerClear))
        path.addLine(to: CGPoint(x: midX, y: midY - outerLen))
        // West
        path.move(to: CGPoint(x: midX - innerClear, y: midY))
        path.addLine(to: CGPoint(x: midX - outerLen, y: midY))
        // East
        path.move(to: CGPoint(x: midX + innerClear, y: midY))
        path.addLine(to: CGPoint(x: midX + outerLen, y: midY))

        // 3. Vernier sub-scale hash ticks across hairlines at radius 24pt
        let hashRadius: CGFloat = 24.0
        let hashHalf: CGFloat = 3.5

        // North tick
        path.move(to: CGPoint(x: midX - hashHalf, y: midY + hashRadius))
        path.addLine(to: CGPoint(x: midX + hashHalf, y: midY + hashRadius))
        // South tick
        path.move(to: CGPoint(x: midX - hashHalf, y: midY - hashRadius))
        path.addLine(to: CGPoint(x: midX + hashHalf, y: midY - hashRadius))
        // West tick
        path.move(to: CGPoint(x: midX - hashRadius, y: midY - hashHalf))
        path.addLine(to: CGPoint(x: midX - hashRadius, y: midY + hashHalf))
        // East tick
        path.move(to: CGPoint(x: midX + hashRadius, y: midY - hashHalf))
        path.addLine(to: CGPoint(x: midX + hashRadius, y: midY + hashHalf))

        // Dual-Stroke Reticle: Solid Black backing for 100% legibility over bright specular areas (e.g. windshield glare, sky, snow)
        let darkBacking = CAShapeLayer()
        darkBacking.path = path
        darkBacking.strokeColor = NSColor.black.withAlphaComponent(0.95).cgColor
        darkBacking.lineWidth = 2.6
        darkBacking.fillColor = nil
        darkBacking.lineCap = .round

        // Brilliant pure white optical hairline core
        let hairline = CAShapeLayer()
        hairline.path = path
        hairline.strokeColor = NSColor.white.withAlphaComponent(1.0).cgColor
        hairline.lineWidth = 1.0
        hairline.fillColor = nil
        hairline.lineCap = .round

        reticleLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        reticleLayer.addSublayer(darkBacking)
        reticleLayer.addSublayer(hairline)
    }

    private func setupThemeObserver() {
        NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateTheme()
            }
        }
    }

    public func updateTheme() {
        let theme = ThemeManager.shared
        let isDark = theme.isDark

        // 1. Overall View Shadow: consistent with Glance HUD floating elevation
        let shadow = NSShadow()
        shadow.shadowColor = theme.shadowColor
        shadow.shadowBlurRadius = isDark ? 20 : 16
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        self.shadow = shadow

        // Ensure badgeView maintains its pill shape and layer masks
        badgeView.layer?.cornerRadius = badgeHeight / 2.0 // 10.0pt capsule
        badgeView.layer?.cornerCurve = .continuous
        badgeView.layer?.masksToBounds = true

        // 2. Translucent Frosted Glass Barrel: matches Glance Frosted Glass design language
        if isDark {
            barrelContainer.backgroundColor = NSColor(deviceWhite: 0.08, alpha: 0.85).cgColor
            outerChamferLayer.borderColor = theme.glassBorderColor
            innerChamferLayer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
            bezelEngravingsLayer.strokeColor = NSColor.white.withAlphaComponent(0.40).cgColor

            badgeView.appearance = theme.glassAppearance
            badgeView.layer?.backgroundColor = theme.wellBackgroundColor
            badgeView.layer?.borderColor = theme.pillBorderColor
            badgeLabel.textColor = theme.primaryTextColor

            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.80)
            textShadow.shadowOffset = NSSize(width: 0, height: -1)
            textShadow.shadowBlurRadius = 2
            badgeLabel.shadow = textShadow
        } else {
            // Light Frosted Platinum Glass (semi-translucent, matches Glance Light HUD)
            barrelContainer.backgroundColor = NSColor(deviceWhite: 0.93, alpha: 0.82).cgColor
            outerChamferLayer.borderColor = theme.glassBorderColor
            innerChamferLayer.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
            bezelEngravingsLayer.strokeColor = NSColor.black.withAlphaComponent(0.50).cgColor

            badgeView.appearance = theme.glassAppearance
            badgeView.layer?.backgroundColor = theme.wellBackgroundColor
            badgeView.layer?.borderColor = theme.pillBorderColor
            badgeLabel.textColor = theme.primaryTextColor
            badgeLabel.shadow = nil
        }

        updateBadgeVisuals()
    }

    private func updateBadgeVisuals() {
        let theme = ThemeManager.shared
        let isDark = theme.isDark

        if magnification == 4.0 {
            badgeLabel.stringValue = "4×"
            badgeDot.backgroundColor = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.05, alpha: 1.0).cgColor // Vibrant amber
            badgeDot.borderColor = NSColor.black.withAlphaComponent(isDark ? 0.4 : 0.25).cgColor
            badgeDot.borderWidth = 0.5
        } else {
            badgeLabel.stringValue = "2×"
            // High-contrast dot: crisp white in dark mode, dark slate in light mode
            badgeDot.backgroundColor = isDark
                ? NSColor(white: 0.92, alpha: 1.0).cgColor
                : NSColor(white: 0.20, alpha: 1.0).cgColor
            badgeDot.borderColor = isDark ? nil : NSColor.white.withAlphaComponent(0.5).cgColor
            badgeDot.borderWidth = isDark ? 0.0 : 0.5
        }
    }

    // MARK: - Presentation Lifecycle

    public func present() {
        isPresented = true
        isHidden = false
        CursorLoupeView.hideSystemCursor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            self.animator().alphaValue = 1.0
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    public func dismiss() {
        guard isPresented else { return }
        isPresented = false
        CursorLoupeView.unhideSystemCursor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            self.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if let self = self, !self.isPresented {
                    self.isHidden = true
                }
            }
        }
    }

    public func toggle() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    public func cycleMagnification() {
        if magnification == 2.0 {
            setMagnification(4.0)
        } else {
            setMagnification(2.0)
        }
    }

    public func setMagnification(_ mag: CGFloat) {
        magnification = (mag >= 3.0) ? 4.0 : 2.0
        updateBadgeVisuals()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    // MARK: - Positioning & Real-Time Hardware Sampling

    /// Smoothly updates the loupe position centered on the mouse and samples the image sub-region
    public func updatePosition(mousePt: CGPoint, in slideView: SlideView) {
        guard isPresented else { return }

        // 1. Position Clamping: keep circular loupe + floating badge fully visible within viewport
        let halfX = totalDiameter / 2.0
        let opticalCenterY = barrelOffsetY + totalDiameter / 2.0 // 28 + 113 = 141.0
        var targetX = mousePt.x - halfX
        var targetY = mousePt.y - opticalCenterY

        let pad: CGFloat = 12.0
        targetX = max(pad, min(slideView.bounds.width - totalDiameter - pad, targetX))
        targetY = max(pad, min(slideView.bounds.height - totalHeight - pad, targetY))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame.origin = CGPoint(x: targetX, y: targetY)
        CATransaction.commit()

        CursorLoupeView.hideSystemCursor()

        // 2. Sample underlying pane image
        guard let info = slideView.imageInfoForPoint(mousePt) else {
            magnifiedLayer.contents = nil
            return
        }

        let img = info.image
        let rect = info.imageRectInView

        // Normalized cursor coordinate within actual photo bounds
        let clampedX = max(rect.minX, min(rect.maxX, mousePt.x))
        let clampedY = max(rect.minY, min(rect.maxY, mousePt.y))

        let u = (clampedX - rect.minX) / rect.width
        let v = (clampedY - rect.minY) / rect.height

        let spanX = (glassDiameter / rect.width) / magnification
        let spanY = (glassDiameter / rect.height) / magnification

        let originX = u - spanX / 2.0
        let originY = v - spanY / 2.0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        magnifiedLayer.contents = img
        magnifiedLayer.contentsRect = CGRect(x: originX, y: originY, width: spanX, height: spanY)
        CATransaction.commit()
    }
}
