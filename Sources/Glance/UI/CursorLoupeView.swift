import AppKit
import CoreGraphics

/// Floating circular optical magnifier loupe (2× / 4×) hovering smoothly over the cursor
/// without displacing or zooming the overall photo framing.
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

    private let diameter: CGFloat = 210.0
    private let clipContainer = NSView()
    private let magnifiedLayer = CALayer()
    private let outerRimLayer = CALayer()
    private let innerRimLayer = CALayer()
    private let crosshairLayer = CALayer()

    private let badgeView = NSVisualEffectView()
    private let badgeLabel = NSTextField(labelWithString: "2×")

    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        setupUI()
        setupThemeObserver()
    }

    public required init?(coder: NSCoder) {
        nil
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Clicks inside circular aperture interact with loupe; outside passes through to photo pane
        let center = CGPoint(x: diameter / 2.0, y: diameter / 2.0)
        let dist = hypot(point.x - center.x, point.y - center.y)
        if dist <= diameter / 2.0 {
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

        // Subtle, physical floating shadow without muddy over-the-top spread
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow

        // 1. Circular clipping container
        clipContainer.wantsLayer = true
        clipContainer.frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        if let cl = clipContainer.layer {
            cl.cornerRadius = diameter / 2.0
            cl.cornerCurve = .circular
            cl.masksToBounds = true
            cl.backgroundColor = NSColor.black.cgColor
        }
        addSubview(clipContainer)

        // 2. Magnified image layer
        magnifiedLayer.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        magnifiedLayer.contentsGravity = .resize
        magnifiedLayer.minificationFilter = .trilinear
        magnifiedLayer.magnificationFilter = .linear
        magnifiedLayer.actions = [
            "contents": NSNull(),
            "contentsRect": NSNull(),
            "position": NSNull(),
            "bounds": NSNull()
        ]
        clipContainer.layer?.addSublayer(magnifiedLayer)

        // 3. Precision Etched Reticle (Hairline with clear 12pt center)
        crosshairLayer.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        crosshairLayer.actions = [
            "contents": NSNull(),
            "opacity": NSNull()
        ]
        drawCrosshair()
        clipContainer.layer?.addSublayer(crosshairLayer)

        // 4. Optical Chamfered Dual-Rim Bezel
        // Outer rim
        outerRimLayer.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        outerRimLayer.cornerRadius = diameter / 2.0
        outerRimLayer.cornerCurve = .circular
        outerRimLayer.borderWidth = 1.5
        outerRimLayer.actions = [
            "borderColor": NSNull(),
            "borderWidth": NSNull()
        ]
        layer?.addSublayer(outerRimLayer)

        // Inner subtle specular accent ring
        let innerInset: CGFloat = 1.5
        innerRimLayer.frame = CGRect(
            x: innerInset,
            y: innerInset,
            width: diameter - 2 * innerInset,
            height: diameter - 2 * innerInset
        )
        innerRimLayer.cornerRadius = (diameter - 2 * innerInset) / 2.0
        innerRimLayer.cornerCurve = .circular
        innerRimLayer.borderWidth = 0.75
        innerRimLayer.actions = [
            "borderColor": NSNull(),
            "borderWidth": NSNull()
        ]
        layer?.addSublayer(innerRimLayer)

        // 5. Floating Magnification Badge Pill [ 2× / 4× ]
        badgeView.material = .hudWindow
        badgeView.blendingMode = .withinWindow
        badgeView.state = .active
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 8.5
        badgeView.layer?.cornerCurve = .continuous
        badgeView.layer?.borderWidth = 0.5
        badgeView.layer?.masksToBounds = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        badgeLabel.alignment = .center
        badgeLabel.textColor = .white
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeView.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.topAnchor.constraint(equalTo: badgeView.topAnchor, constant: 2),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: -2),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 8),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -8)
        ])

        addSubview(badgeView)
        NSLayoutConstraint.activate([
            badgeView.centerXAnchor.constraint(equalTo: centerXAnchor),
            badgeView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            badgeView.heightAnchor.constraint(equalToConstant: 19)
        ])

        updateTheme()
    }

    private func drawCrosshair() {
        let midX = diameter / 2.0
        let midY = diameter / 2.0
        let innerGap: CGFloat = 6.0
        let outerLen: CGFloat = 11.0

        let path = CGMutablePath()
        // North
        path.move(to: CGPoint(x: midX, y: midY + innerGap))
        path.addLine(to: CGPoint(x: midX, y: midY + innerGap + outerLen))
        // South
        path.move(to: CGPoint(x: midX, y: midY - innerGap))
        path.addLine(to: CGPoint(x: midX, y: midY - innerGap - outerLen))
        // West
        path.move(to: CGPoint(x: midX - innerGap, y: midY))
        path.addLine(to: CGPoint(x: midX - innerGap - outerLen, y: midY))
        // East
        path.move(to: CGPoint(x: midX + innerGap, y: midY))
        path.addLine(to: CGPoint(x: midX + innerGap + outerLen, y: midY))

        // Subtle dark outline for razor contrast over specular highlights
        let darkOutline = CAShapeLayer()
        darkOutline.path = path
        darkOutline.strokeColor = NSColor.black.withAlphaComponent(0.40).cgColor
        darkOutline.lineWidth = 2.0
        darkOutline.lineCap = .round

        // Precision optical hairline
        let hairline = CAShapeLayer()
        hairline.path = path
        hairline.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        hairline.lineWidth = 1.0
        hairline.lineCap = .round

        crosshairLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        crosshairLayer.addSublayer(darkOutline)
        crosshairLayer.addSublayer(hairline)
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
        let isDark = ThemeManager.shared.isDark
        if isDark {
            outerRimLayer.borderColor = NSColor(white: 1.0, alpha: 0.35).cgColor
            innerRimLayer.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
            badgeView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.28).cgColor
            badgeView.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.55).cgColor
            badgeLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        } else {
            outerRimLayer.borderColor = NSColor(white: 0.15, alpha: 0.30).cgColor
            innerRimLayer.borderColor = NSColor(white: 1.0, alpha: 0.45).cgColor
            badgeView.layer?.borderColor = NSColor(white: 0.10, alpha: 0.22).cgColor
            badgeView.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.70).cgColor
            badgeLabel.textColor = NSColor(white: 0.10, alpha: 1.0)
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
        badgeLabel.stringValue = String(format: "%.0f×", magnification)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    // MARK: - Positioning & Real-Time Hardware Sampling

    /// Smoothly updates the loupe position centered on the mouse and samples the image sub-region
    public func updatePosition(mousePt: CGPoint, in slideView: SlideView) {
        guard isPresented else { return }

        // 1. Position Clamping: keep circular loupe fully visible within viewport
        let half = diameter / 2.0
        var targetX = mousePt.x - half
        var targetY = mousePt.y - half

        let pad: CGFloat = 14.0
        targetX = max(pad, min(slideView.bounds.width - diameter - pad, targetX))
        targetY = max(pad, min(slideView.bounds.height - diameter - pad, targetY))

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

        let spanX = (diameter / rect.width) / magnification
        let spanY = (diameter / rect.height) / magnification

        let originX = u - spanX / 2.0
        let originY = v - spanY / 2.0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        magnifiedLayer.contents = img
        magnifiedLayer.contentsRect = CGRect(x: originX, y: originY, width: spanX, height: spanY)
        CATransaction.commit()
    }
}
