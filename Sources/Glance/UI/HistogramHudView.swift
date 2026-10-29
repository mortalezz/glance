import AppKit
import Accelerate

/// A dedicated canvas view that renders multi-channel curves (Red, Green, Blue, Luminance)
/// over a tonal grid using square-root scaling, outlier suppression, and additive RGB blending.
final class HistogramCanvasView: NSView {
    private var data: HistogramData = .empty

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    public func update(with data: HistogramData) {
        self.data = data
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let rect = bounds
        guard rect.width > 10 && rect.height > 10 else { return }

        // 1. Subtle exposure zone dividers (25% Shadows, 50% Midtones, 75% Highlights)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(0.75)

        for fraction in [0.25, 0.50, 0.75] {
            let x = floor(rect.minX + rect.width * CGFloat(fraction)) + 0.5
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
        }

        // Subtle horizontal mid-level guide
        let midY = floor(rect.minY + rect.height * 0.5) + 0.5
        ctx.move(to: CGPoint(x: rect.minX, y: midY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: midY))
        ctx.strokePath()
        ctx.restoreGState()

        // 2. Outlier-suppressed peak determination (ignore edge spikes 0-1 and 254-255 so midtones aren't flattened)
        var peak: Double = 1.0
        for i in 2..<254 {
            let rVal = Double(data.red[i])
            let gVal = Double(data.green[i])
            let bVal = Double(data.blue[i])
            let lVal = Double(data.luminance[i])
            if rVal > peak { peak = rVal }
            if gVal > peak { peak = gVal }
            if bVal > peak { peak = bVal }
            if lVal > peak { peak = lVal }
        }
        if peak <= 1.0 {
            peak = max(1.0, Double(data.maxCount))
        }

        let sqrtPeak = sqrt(peak)
        let bottomPad: CGFloat = 2.0
        let topPad: CGFloat = 4.0
        let usableHeight = max(1.0, rect.height - bottomPad - topPad)

        // 3. Binomial smoothing filter [0.25, 0.50, 0.25] to prevent quantization comb noise
        func smoothedBins(_ bins: [vImagePixelCount]) -> [Double] {
            var res = [Double](repeating: 0, count: 256)
            for i in 0..<256 {
                let left = i > 0 ? Double(bins[i - 1]) : Double(bins[0])
                let center = Double(bins[i])
                let right = i < 255 ? Double(bins[i + 1]) : Double(bins[255])
                res[i] = 0.25 * left + 0.50 * center + 0.25 * right
            }
            return res
        }

        let rSmooth = smoothedBins(data.red)
        let gSmooth = smoothedBins(data.green)
        let bSmooth = smoothedBins(data.blue)
        let lSmooth = smoothedBins(data.luminance)

        // Helper to construct closed fill path and contour stroke path
        func buildPaths(for bins: [Double]) -> (fill: CGPath, stroke: CGPath) {
            let fillPath = CGMutablePath()
            let strokePath = CGMutablePath()

            fillPath.move(to: CGPoint(x: rect.minX, y: rect.minY + bottomPad))

            for i in 0..<256 {
                let x = rect.minX + (CGFloat(i) / 255.0) * rect.width
                let norm = min(1.0, sqrt(bins[i]) / sqrtPeak)
                let y = rect.minY + bottomPad + CGFloat(norm) * usableHeight

                fillPath.addLine(to: CGPoint(x: x, y: y))
                if i == 0 {
                    strokePath.move(to: CGPoint(x: x, y: y))
                } else {
                    strokePath.addLine(to: CGPoint(x: x, y: y))
                }
            }

            fillPath.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bottomPad))
            fillPath.closeSubpath()

            return (fillPath, strokePath)
        }

        let (rFill, rStroke) = buildPaths(for: rSmooth)
        let (gFill, gStroke) = buildPaths(for: gSmooth)
        let (bFill, bStroke) = buildPaths(for: bSmooth)
        let (_, lStroke) = buildPaths(for: lSmooth)

        // 4. Additive Screen Fills (Overlapping Red + Green = Yellow, Green + Blue = Cyan, Red + Blue = Magenta, R+G+B = White)
        ctx.saveGState()
        ctx.setBlendMode(.screen)

        // Red Fill
        ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.18, alpha: 0.48).cgColor)
        ctx.addPath(rFill)
        ctx.fillPath()

        // Green Fill
        ctx.setFillColor(NSColor(calibratedRed: 0.12, green: 0.95, blue: 0.28, alpha: 0.48).cgColor)
        ctx.addPath(gFill)
        ctx.fillPath()

        // Blue Fill
        ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.50, blue: 1.0, alpha: 0.52).cgColor)
        ctx.addPath(bFill)
        ctx.fillPath()

        ctx.restoreGState()

        // 5. Crisp Contour Strokes along channel crests
        ctx.saveGState()
        ctx.setLineWidth(1.0)

        ctx.setStrokeColor(NSColor(calibratedRed: 1.0, green: 0.25, blue: 0.30, alpha: 0.75).cgColor)
        ctx.addPath(rStroke)
        ctx.strokePath()

        ctx.setStrokeColor(NSColor(calibratedRed: 0.25, green: 1.0, blue: 0.40, alpha: 0.75).cgColor)
        ctx.addPath(gStroke)
        ctx.strokePath()

        ctx.setStrokeColor(NSColor(calibratedRed: 0.30, green: 0.65, blue: 1.0, alpha: 0.80).cgColor)
        ctx.addPath(bStroke)
        ctx.strokePath()

        // 6. Razor-sharp Luminance curve on top
        ctx.setStrokeColor(NSColor(white: 0.95, alpha: 0.85).cgColor)
        ctx.setLineWidth(1.2)
        ctx.addPath(lStroke)
        ctx.strokePath()

        ctx.restoreGState()
    }
}

/// Lightroom Classic-style corner triangle clipping indicator for shadows or highlights.
final class ClippingTriangleView: NSView {
    enum Kind {
        case shadow
        case highlight
    }

    private let kind: Kind
    public var isClipped: Bool = false {
        didSet {
            if oldValue != isClipped {
                needsDisplay = true
            }
        }
    }
    public var onClick: (() -> Void)?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let rect = bounds
        guard rect.width >= 8 && rect.height >= 8 else { return }

        let bgPath = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(bgPath)

        if isClipped {
            let activeColor = (kind == .shadow)
                ? NSColor(calibratedRed: 0.05, green: 0.50, blue: 1.0, alpha: 0.85)
                : NSColor(calibratedRed: 1.0, green: 0.15, blue: 0.20, alpha: 0.85)
            ctx.setFillColor(activeColor.cgColor)
            ctx.fillPath()
        } else {
            ctx.setFillColor(NSColor(white: 0.15, alpha: 0.40).cgColor)
            ctx.fillPath()
            ctx.addPath(bgPath)
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.15).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
        }

        // Triangle glyph pointing into the corner
        let trianglePath = CGMutablePath()
        let inset = rect.insetBy(dx: 3.5, dy: 3.5)

        switch kind {
        case .shadow:
            // Triangle pointing to top-left corner
            trianglePath.move(to: CGPoint(x: inset.minX, y: inset.maxY))
            trianglePath.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
            trianglePath.addLine(to: CGPoint(x: inset.minX, y: inset.minY))
            trianglePath.closeSubpath()
        case .highlight:
            // Triangle pointing to top-right corner
            trianglePath.move(to: CGPoint(x: inset.maxX, y: inset.maxY))
            trianglePath.addLine(to: CGPoint(x: inset.maxX, y: inset.minY))
            trianglePath.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
            trianglePath.closeSubpath()
        }

        ctx.addPath(trianglePath)
        if isClipped {
            ctx.setFillColor(NSColor.white.cgColor)
        } else {
            ctx.setFillColor(NSColor(white: 1.0, alpha: 0.35).cgColor)
        }
        ctx.fillPath()
    }
}

/// Modern macOS frosted-glass HUD overlay displaying a live RGB & Luminance histogram.
@MainActor
public final class HistogramHudView: NSView {
    private let visualEffectView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "HISTOGRAM")
    private let canvasContainer = NSView()
    private let canvas = HistogramCanvasView()

    private let shadowClipIndicator = ClippingTriangleView(kind: .shadow)
    private let highlightClipIndicator = ClippingTriangleView(kind: .highlight)

    public var onToggleClipping: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
        setupContent()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGlass()
        setupContent()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let ptInShadow = shadowClipIndicator.convert(point, from: self)
        if shadowClipIndicator.bounds.contains(ptInShadow) {
            return shadowClipIndicator
        }
        let ptInHighlight = highlightClipIndicator.convert(point, from: self)
        if highlightClipIndicator.bounds.contains(ptInHighlight) {
            return highlightClipIndicator
        }
        return nil
    }

    private func setupGlass() {
        wantsLayer = true
        alphaValue = 0.0

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.50)
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowBlurRadius = 18
        self.shadow = shadow

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.appearance = NSAppearance(named: .vibrantDark)
        visualEffectView.wantsLayer = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false

        if let layer = visualEffectView.layer {
            layer.cornerRadius = 14
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
            layer.borderWidth = 0.75
        }

        // Dark scrim backdrop guarantees high-contrast legibility against bright backgrounds
        let scrimView = NSView()
        scrimView.wantsLayer = true
        scrimView.layer?.backgroundColor = NSColor(deviceWhite: 0.05, alpha: 0.65).cgColor
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(scrimView)
        NSLayoutConstraint.activate([
            scrimView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor)
        ])

        addSubview(visualEffectView)
        NSLayoutConstraint.activate([
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    private func setupContent() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(root)

        // 1. Header Row: Clean Title & Channel Legend with comfortable inner margins
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        // Title with uppercase tracking
        let attrTitle = NSMutableAttributedString(
            string: "HISTOGRAM",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor(white: 0.88, alpha: 1.0),
                .kern: 0.8
            ]
        )
        titleLabel.attributedStringValue = attrTitle
        header.addArrangedSubview(titleLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)

        // Channel Legend: [• R] [• G] [• B] [• L]
        let legend = NSStackView()
        legend.orientation = .horizontal
        legend.alignment = .centerY
        legend.spacing = 7

        legend.addArrangedSubview(makeLegendBadge(color: NSColor(calibratedRed: 1.0, green: 0.22, blue: 0.26, alpha: 1.0), label: "R"))
        legend.addArrangedSubview(makeLegendBadge(color: NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.35, alpha: 1.0), label: "G"))
        legend.addArrangedSubview(makeLegendBadge(color: NSColor(calibratedRed: 0.20, green: 0.60, blue: 1.0, alpha: 1.0), label: "B"))
        legend.addArrangedSubview(makeLegendBadge(color: NSColor(white: 0.95, alpha: 1.0), label: "L"))
        header.addArrangedSubview(legend)

        root.addArrangedSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])

        // 2. Recessed Scope Container with Dark Frosted Well
        canvasContainer.translatesAutoresizingMaskIntoConstraints = false
        canvasContainer.wantsLayer = true
        if let layer = canvasContainer.layer {
            layer.backgroundColor = NSColor(deviceWhite: 0.05, alpha: 0.55).cgColor
            layer.cornerRadius = 7
            layer.cornerCurve = .continuous
            layer.borderWidth = 0.5
            layer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            layer.masksToBounds = true
        }

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvasContainer.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: canvasContainer.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: canvasContainer.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: canvasContainer.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: canvasContainer.trailingAnchor)
        ])

        // Lightroom-style corner triangle clipping indicators inside the scope well
        shadowClipIndicator.onClick = { [weak self] in
            self?.onToggleClipping?()
        }
        highlightClipIndicator.onClick = { [weak self] in
            self?.onToggleClipping?()
        }

        canvasContainer.addSubview(shadowClipIndicator)
        canvasContainer.addSubview(highlightClipIndicator)

        NSLayoutConstraint.activate([
            shadowClipIndicator.topAnchor.constraint(equalTo: canvasContainer.topAnchor, constant: 6),
            shadowClipIndicator.leadingAnchor.constraint(equalTo: canvasContainer.leadingAnchor, constant: 6),
            shadowClipIndicator.widthAnchor.constraint(equalToConstant: 14),
            shadowClipIndicator.heightAnchor.constraint(equalToConstant: 14),

            highlightClipIndicator.topAnchor.constraint(equalTo: canvasContainer.topAnchor, constant: 6),
            highlightClipIndicator.trailingAnchor.constraint(equalTo: canvasContainer.trailingAnchor, constant: -6),
            highlightClipIndicator.widthAnchor.constraint(equalToConstant: 14),
            highlightClipIndicator.heightAnchor.constraint(equalToConstant: 14)
        ])

        root.addArrangedSubview(canvasContainer)
        NSLayoutConstraint.activate([
            canvasContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvasContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvasContainer.heightAnchor.constraint(equalToConstant: 96)
        ])

        // 3. Footer Row: Exposure Zone Labels (SHADOWS, EXPOSURE, HIGHLIGHTS)
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .equalSpacing
        footer.translatesAutoresizingMaskIntoConstraints = false

        footer.addArrangedSubview(makeFooterLabel(title: "SHADOWS"))
        footer.addArrangedSubview(makeFooterLabel(title: "EXPOSURE"))
        footer.addArrangedSubview(makeFooterLabel(title: "HIGHLIGHTS"))

        root.addArrangedSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4)
        ])

        // Generous, balanced insets from HUD window edges (14pt left/right, 12pt top, 10pt bottom)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -10),
            root.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -14)
        ])
    }

    private func makeLegendBadge(color: NSColor, label: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5)
        ])
        stack.addArrangedSubview(dot)

        let tf = NSTextField(labelWithString: label)
        tf.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        tf.textColor = NSColor(white: 0.78, alpha: 1.0)
        stack.addArrangedSubview(tf)

        return stack
    }

    private func makeFooterLabel(title: String) -> NSTextField {
        let tf = NSTextField(labelWithString: title)
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor(white: 1.0, alpha: 0.35),
                .kern: 0.6
            ]
        )
        tf.attributedStringValue = attr
        return tf
    }

    public func update(with data: HistogramData) {
        canvas.update(with: data)

        // Update clipping indicators:
        let hasShadowClip = (data.red[0] > 30 || data.green[0] > 30 || data.blue[0] > 30)
        let hasHighlightClip = (data.red[255] > 30 || data.green[255] > 30 || data.blue[255] > 30)

        shadowClipIndicator.isClipped = hasShadowClip
        highlightClipIndicator.isClipped = hasHighlightClip
    }

    public func setVisible(_ visible: Bool, animated: Bool = true) {
        let targetAlpha: CGFloat = visible ? 1.0 : 0.0
        guard alphaValue != targetAlpha else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                self.animator().alphaValue = targetAlpha
            }
        } else {
            alphaValue = targetAlpha
        }
    }
}
