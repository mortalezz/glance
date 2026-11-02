import AppKit

/// Interactive inner thumbnail canvas for the 1:1 Loupe Navigator Mini-Map.
/// Renders the scaled-down preview of the active image, displays a high-contrast
/// emerald viewport rectangle representing the currently visible zoom region,
/// and handles real-time 120Hz click-to-center and drag-to-pan gestures.
@MainActor
public final class NavigatorThumbnailView: NSView {
    public var onPanToNormalizedPoint: ((CGPoint) -> Void)?

    private let imageLayer = CALayer()
    private let viewportBoxLayer = CALayer()
    private let centerDotLayer = CALayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 6.0
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        // Base image layer
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull()
        ]
        layer?.addSublayer(imageLayer)

        // Viewport highlight box (High-visibility emerald rim)
        viewportBoxLayer.borderWidth = 1.5
        viewportBoxLayer.borderColor = NSColor(srgbRed: 0.20, green: 0.88, blue: 0.58, alpha: 0.95).cgColor
        viewportBoxLayer.backgroundColor = NSColor(srgbRed: 0.20, green: 0.88, blue: 0.58, alpha: 0.16).cgColor
        viewportBoxLayer.cornerRadius = 2.0
        viewportBoxLayer.shadowColor = NSColor.black.cgColor
        viewportBoxLayer.shadowOpacity = 0.65
        viewportBoxLayer.shadowRadius = 2.0
        viewportBoxLayer.shadowOffset = .zero
        viewportBoxLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "borderColor": NSNull(),
            "backgroundColor": NSNull()
        ]
        layer?.addSublayer(viewportBoxLayer)

        // Subtle center crosshair pip inside viewport box
        centerDotLayer.backgroundColor = NSColor(srgbRed: 0.20, green: 0.88, blue: 0.58, alpha: 0.90).cgColor
        centerDotLayer.cornerRadius = 1.0
        centerDotLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull()
        ]
        viewportBoxLayer.addSublayer(centerDotLayer)
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    public func setImage(_ cgImage: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = cgImage
        CATransaction.commit()
    }

    public func updateViewport(normalizedRect: CGRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let w = max(4.0, normalizedRect.width * bounds.width)
        let h = max(4.0, normalizedRect.height * bounds.height)
        let x = max(0.0, min(bounds.width - w, normalizedRect.origin.x * bounds.width))
        let y = max(0.0, min(bounds.height - h, normalizedRect.origin.y * bounds.height))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let boxFrame = CGRect(x: x, y: y, width: w, height: h)
        viewportBoxLayer.frame = boxFrame
        centerDotLayer.frame = CGRect(x: (w - 2.0) / 2.0, y: (h - 2.0) / 2.0, width: 2.0, height: 2.0)
        CATransaction.commit()
    }

    // MARK: - Mouse Event Handling

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    public override func mouseDown(with event: NSEvent) {
        handleMouse(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        handleMouse(event)
    }

    private func handleMouse(_ event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let normX = max(0.0, min(1.0, loc.x / bounds.width))
        let normY = max(0.0, min(1.0, loc.y / bounds.height))
        onPanToNormalizedPoint?(CGPoint(x: normX, y: normY))
    }
}

/// Floating Glass Picture-in-Picture (PiP) 1:1 Loupe Navigator Mini-Map.
/// Built strictly on `ThemedGlassCardView(cornerRadius: 12)` adhering to Glance HIG.
/// Displays an interactive full-image thumbnail, an emerald viewport highlight box,
/// and supports click/drag panning and one-click collapsible mini pill mode.
@MainActor
public final class NavigatorMiniMapView: ThemedGlassCardView {
    public var onPanToNormalizedPoint: ((CGPoint) -> Void)?
    public var onCollapseStateChanged: ((Bool) -> Void)?

    public private(set) var isPresented: Bool = false
    public private(set) var isCollapsed: Bool = false

    public let thumbnailView = NavigatorThumbnailView()

    // Header views
    private let headerContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "NAVIGATOR")
    private let zoomBadge = NSTextField(labelWithString: "1:1")
    private let zoomBadgePill = NSView()
    private let collapseButton = NSButton()

    // Collapsed pill view
    private let collapsedContainer = NSView()
    private let collapsedIcon = NSTextField(labelWithString: "🧭")
    private let collapsedLabel = NSTextField(labelWithString: "NAV 1:1")

    // Dynamic layout constraints
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    private var currentImageAspect: CGFloat = 1.5 // width / height

    public init() {
        super.init(cornerRadius: 12.0)
        setupContent()
        applyTheme()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupContent()
        applyTheme()
    }

    private func setupContent() {
        isHidden = true
        alphaValue = 0.0

        // 1. Header Container
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerContainer)

        // Title
        let attrTitle = NSMutableAttributedString(
            string: "NAVIGATOR",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.0, weight: .bold),
                .kern: 0.8
            ]
        )
        titleLabel.attributedStringValue = attrTitle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(titleLabel)

        // 1:1 Zoom Badge Pill
        zoomBadgePill.wantsLayer = true
        zoomBadgePill.layer?.cornerRadius = 3.5
        zoomBadgePill.layer?.cornerCurve = .continuous
        zoomBadgePill.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(zoomBadgePill)

        zoomBadge.font = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
        zoomBadge.textColor = NSColor(srgbRed: 0.20, green: 0.88, blue: 0.58, alpha: 0.95)
        zoomBadge.translatesAutoresizingMaskIntoConstraints = false
        zoomBadgePill.addSubview(zoomBadge)

        // Collapse Button
        collapseButton.isBordered = false
        collapseButton.bezelStyle = .inline
        if #available(macOS 11.0, *) {
            collapseButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Minimize Navigator")
        } else {
            collapseButton.title = "−"
        }
        collapseButton.imageScaling = .scaleProportionallyDown
        collapseButton.target = self
        collapseButton.action = #selector(handleCollapseButtonClicked)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(collapseButton)

        // 2. Thumbnail View
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.onPanToNormalizedPoint = { [weak self] normPt in
            self?.onPanToNormalizedPoint?(normPt)
        }
        contentView.addSubview(thumbnailView)

        // 3. Collapsed Container
        collapsedContainer.translatesAutoresizingMaskIntoConstraints = false
        collapsedContainer.isHidden = true
        contentView.addSubview(collapsedContainer)

        collapsedIcon.font = NSFont.systemFont(ofSize: 11.0)
        collapsedIcon.translatesAutoresizingMaskIntoConstraints = false
        collapsedContainer.addSubview(collapsedIcon)

        let attrCollapsed = NSMutableAttributedString(
            string: "NAV 1:1",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .kern: 0.6
            ]
        )
        collapsedLabel.attributedStringValue = attrCollapsed
        collapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        collapsedContainer.addSubview(collapsedLabel)

        // Layout constraints
        let w = widthAnchor.constraint(equalToConstant: 168.0)
        let h = heightAnchor.constraint(equalToConstant: 142.0)
        self.widthConstraint = w
        self.heightConstraint = h

        NSLayoutConstraint.activate([
            w,
            h,

            // Header
            headerContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            headerContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            headerContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            headerContainer.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            zoomBadgePill.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 5),
            zoomBadgePill.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            zoomBadgePill.heightAnchor.constraint(equalToConstant: 13),

            zoomBadge.topAnchor.constraint(equalTo: zoomBadgePill.topAnchor, constant: 0.5),
            zoomBadge.bottomAnchor.constraint(equalTo: zoomBadgePill.bottomAnchor, constant: -0.5),
            zoomBadge.leadingAnchor.constraint(equalTo: zoomBadgePill.leadingAnchor, constant: 4),
            zoomBadge.trailingAnchor.constraint(equalTo: zoomBadgePill.trailingAnchor, constant: -4),

            collapseButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            collapseButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            collapseButton.widthAnchor.constraint(equalToConstant: 16),
            collapseButton.heightAnchor.constraint(equalToConstant: 16),

            // Thumbnail
            thumbnailView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 4),
            thumbnailView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            thumbnailView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            thumbnailView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            // Collapsed Pill View
            collapsedContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            collapsedContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            collapsedContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            collapsedContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),

            collapsedIcon.leadingAnchor.constraint(equalTo: collapsedContainer.leadingAnchor),
            collapsedIcon.centerYAnchor.constraint(equalTo: collapsedContainer.centerYAnchor),

            collapsedLabel.leadingAnchor.constraint(equalTo: collapsedIcon.trailingAnchor, constant: 4),
            collapsedLabel.centerYAnchor.constraint(equalTo: collapsedContainer.centerYAnchor),
            collapsedLabel.trailingAnchor.constraint(lessThanOrEqualTo: collapsedContainer.trailingAnchor)
        ])
    }

    @objc private func handleCollapseButtonClicked() {
        toggleCollapse()
    }

    public override func mouseDown(with event: NSEvent) {
        if isCollapsed {
            toggleCollapse()
            return
        }
        if event.clickCount == 2 {
            toggleCollapse()
            return
        }
        // Absorb other clicks so they do not fall through to SlideView
    }

    public func toggleCollapse() {
        isCollapsed.toggle()
        updateCardDimensions(animated: true)
        onCollapseStateChanged?(isCollapsed)
    }

    public func setImage(_ cgImage: CGImage?, dimensions: CGSize) {
        thumbnailView.setImage(cgImage)
        if dimensions.width > 0 && dimensions.height > 0 {
            let aspect = dimensions.width / dimensions.height
            if abs(currentImageAspect - aspect) > 0.02 {
                currentImageAspect = aspect
                updateCardDimensions(animated: false)
            }
        }
    }

    public func setNormalizedViewport(rect: CGRect) {
        thumbnailView.updateViewport(normalizedRect: rect)
    }

    private func updateCardDimensions(animated: Bool) {
        let targetW: CGFloat
        let targetH: CGFloat

        if isCollapsed {
            targetW = 98.0
            targetH = 26.0
            headerContainer.isHidden = true
            thumbnailView.isHidden = true
            collapsedContainer.isHidden = false
            if #available(macOS 11.0, *) {
                collapseButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Expand Navigator")
            }
        } else {
            headerContainer.isHidden = false
            thumbnailView.isHidden = false
            collapsedContainer.isHidden = true
            if #available(macOS 11.0, *) {
                collapseButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Minimize Navigator")
            }

            let thumbW: CGFloat
            let thumbH: CGFloat
            if currentImageAspect >= 1.0 {
                thumbW = 156.0
                thumbH = max(60.0, min(108.0, round(156.0 / currentImageAspect)))
            } else {
                thumbH = 108.0
                thumbW = max(64.0, min(156.0, round(108.0 * currentImageAspect)))
            }

            targetW = thumbW + 12.0
            targetH = thumbH + 18.0 + 4.0 + 6.0 + 6.0
        }

        widthConstraint?.constant = targetW
        heightConstraint?.constant = targetH

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.layoutSubtreeIfNeeded()
            }
        } else {
            layoutSubtreeIfNeeded()
        }
    }

    public func present(animated: Bool = true) {
        guard !isPresented else { return }
        isPresented = true
        isHidden = false
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            }
        } else {
            alphaValue = 1.0
        }
    }

    public func dismiss(animated: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0.0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    if self?.alphaValue == 0.0 {
                        self?.isHidden = true
                    }
                }
            }
        } else {
            alphaValue = 0.0
            isHidden = true
        }
    }

    public override func updateCustomTheme(theme: ThemeManager) {
        let shadow = theme.standardTextShadow

        titleLabel.textColor = theme.secondaryTextColor
        titleLabel.shadow = shadow

        zoomBadgePill.layer?.backgroundColor = theme.isDark
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.black.withAlphaComponent(0.06).cgColor

        zoomBadge.textColor = NSColor(srgbRed: 0.20, green: 0.88, blue: 0.58, alpha: 0.95)

        collapseButton.contentTintColor = theme.secondaryTextColor

        collapsedLabel.textColor = theme.primaryTextColor
        collapsedLabel.shadow = shadow

        thumbnailView.layer?.borderColor = theme.isDark
            ? NSColor.white.withAlphaComponent(0.12).cgColor
            : NSColor.black.withAlphaComponent(0.10).cgColor
        thumbnailView.layer?.backgroundColor = theme.isDark
            ? NSColor.black.withAlphaComponent(0.45).cgColor
            : NSColor.black.withAlphaComponent(0.20).cgColor
    }
}
