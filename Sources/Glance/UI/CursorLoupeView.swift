import AppKit
import CoreGraphics

/// Floating circular optical magnifier loupe (2× / 4×) hovering smoothly over the cursor
/// without displacing or zooming the overall photo framing.
@MainActor
public final class CursorLoupeView: NSView {
    public private(set) var isPresented: Bool = false
    public var isTemporaryGlide: Bool = false
    public private(set) var magnification: CGFloat = 2.0 // 2.0 or 4.0

    private let diameter: CGFloat = 210.0
    private let clipContainer = NSView()
    private let magnifiedLayer = CALayer()
    private let rimLayer = CALayer()
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
        // Completely transparent to mouse clicks & gestures
        return nil
    }

    private func setupUI() {
        wantsLayer = true
        isHidden = true
        alphaValue = 0.0

        // Outer soft shadow on self for physical 3D elevation
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
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

        // 3. Precision Crosshair Reticle (with 8pt center clear zone)
        crosshairLayer.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        crosshairLayer.actions = [
            "contents": NSNull(),
            "opacity": NSNull()
        ]
        drawCrosshair()
        clipContainer.layer?.addSublayer(crosshairLayer)

        // 4. Optical Frosted Rim Bezel
        rimLayer.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        rimLayer.cornerRadius = diameter / 2.0
        rimLayer.cornerCurve = .circular
        rimLayer.borderWidth = 2.0
        rimLayer.actions = [
            "borderColor": NSNull(),
            "borderWidth": NSNull()
        ]
        layer?.addSublayer(rimLayer)

        // 5. Floating Magnification Badge Pill [ 2× / 4× ]
        badgeView.material = .hudWindow
        badgeView.blendingMode = .withinWindow
        badgeView.state = .active
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 9.0
        badgeView.layer?.cornerCurve = .continuous
        badgeView.layer?.borderWidth = 0.5
        badgeView.layer?.masksToBounds = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .heavy)
        badgeLabel.alignment = .center
        badgeLabel.textColor = .white
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        badgeView.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.topAnchor.constraint(equalTo: badgeView.topAnchor, constant: 2),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: -2),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 7),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -7)
        ])

        addSubview(badgeView)
        NSLayoutConstraint.activate([
            badgeView.centerXAnchor.constraint(equalTo: centerXAnchor),
            badgeView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            badgeView.heightAnchor.constraint(equalToConstant: 18)
        ])

        updateTheme()
    }

    private func drawCrosshair() {
        let midX = diameter / 2.0
        let midY = diameter / 2.0
        let innerGap: CGFloat = 4.0
        let outerLen: CGFloat = 13.0

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

        let shape = CAShapeLayer()
        shape.path = path
        shape.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        shape.lineWidth = 1.0
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowRadius = 1.5
        shape.shadowOffset = .zero
        shape.shadowOpacity = 0.9

        crosshairLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        crosshairLayer.addSublayer(shape)
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
            rimLayer.borderColor = NSColor(white: 1.0, alpha: 0.40).cgColor
            badgeView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.30).cgColor
            badgeView.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.50).cgColor
            badgeLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        } else {
            rimLayer.borderColor = NSColor(white: 0.15, alpha: 0.35).cgColor
            badgeView.layer?.borderColor = NSColor(white: 0.10, alpha: 0.25).cgColor
            badgeView.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.65).cgColor
            badgeLabel.textColor = NSColor(white: 0.10, alpha: 1.0)
        }
    }

    // MARK: - Presentation Lifecycle

    public func present(temporary: Bool = false) {
        isPresented = true
        isTemporaryGlide = temporary
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            self.animator().alphaValue = 1.0
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    public func dismiss() {
        guard isPresented else { return }
        isPresented = false
        isTemporaryGlide = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
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
            present(temporary: false)
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
