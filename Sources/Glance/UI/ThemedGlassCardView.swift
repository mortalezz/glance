import AppKit

/// Standardized macOS frosted-glass container card adhering to Glance HIG.
/// Provides an `NSVisualEffectView` blur surface, a dedicated `scrimView` that prevents
/// underlying image/neon-color bleed-through, standard 14pt continuous corners,
/// glass borders, and reactive elevation shadows across Light and Dark themes.
@MainActor
open class ThemedGlassCardView: NSView {
    public let visualEffectView = NSVisualEffectView()
    public let scrimView = NSView()
    public let contentView = NSView()

    private let customCornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 14.0) {
        self.customCornerRadius = cornerRadius
        super.init(frame: .zero)
        setupGlassCardHierarchy()
        setupThemeObserver()
        applyTheme()
    }

    public required init?(coder: NSCoder) {
        self.customCornerRadius = 14.0
        super.init(coder: coder)
        setupGlassCardHierarchy()
        setupThemeObserver()
        applyTheme()
    }

    private func setupGlassCardHierarchy() {
        wantsLayer = true

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false

        if let effectLayer = visualEffectView.layer {
            effectLayer.cornerRadius = customCornerRadius
            effectLayer.cornerCurve = .continuous
            effectLayer.masksToBounds = true
            effectLayer.borderWidth = 0.75
        }

        // Dedicated scrim backing: absolutely critical to prevent high-chroma image
        // or false-color bleed-through from ruining card contrast and legibility.
        scrimView.wantsLayer = true
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(scrimView)
        NSLayoutConstraint.activate([
            scrimView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor)
        ])

        // Content hosting view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor)
        ])

        addSubview(visualEffectView)
        NSLayoutConstraint.activate([
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    private func setupThemeObserver() {
        NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTheme()
            }
        }
    }

    open func applyTheme() {
        let theme = ThemeManager.shared
        visualEffectView.appearance = theme.glassAppearance
        scrimView.layer?.backgroundColor = theme.scrimColor.cgColor
        visualEffectView.layer?.borderColor = theme.glassBorderColor

        let shadow = NSShadow()
        shadow.shadowColor = theme.shadowColor
        shadow.shadowBlurRadius = theme.isDark ? 16 : 12
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        self.shadow = shadow

        updateCustomTheme(theme: theme)
    }

    /// Subclasses override this to rebind text colors, wells, and dividers to semantic tokens
    open func updateCustomTheme(theme: ThemeManager) {}
}

/// Standardized capsule badge pill adhering to Glance HIG.
/// Guarantees capsule corner radius (`height / 2.0`), semantic well/pill backgrounds,
/// and reactive theme typography (clean text in Light mode, soft drop shadow in Dark mode).
@MainActor
open class ThemedPillView: NSView {
    public let visualEffectView = NSVisualEffectView()
    public let label = NSTextField(labelWithString: "")
    public let indicatorDot = CALayer()
    public var hasIndicatorDot: Bool = false {
        didSet {
            indicatorDot.isHidden = !hasIndicatorDot
            updateLayoutConstraints()
        }
    }

    private var leadingConstraint: NSLayoutConstraint?

    public init(text: String = "", hasDot: Bool = false) {
        super.init(frame: .zero)
        self.hasIndicatorDot = hasDot
        label.stringValue = text
        setupUI()
        setupThemeObserver()
        applyTheme()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupThemeObserver()
        applyTheme()
    }

    public override func layout() {
        super.layout()
        let h = bounds.height
        let r = h / 2.0
        visualEffectView.layer?.cornerRadius = r
        layer?.cornerRadius = r

        if hasIndicatorDot {
            let dotSize: CGFloat = 5.0
            let font = label.font ?? NSFont.systemFont(ofSize: 9, weight: .bold)
            let labelH = label.frame.height > 0 ? label.frame.height : label.fittingSize.height
            let labelMinY = (h - labelH) / 2.0
            let capCenterY = labelMinY + (-font.descender + font.capHeight / 2.0)
            let dotY = round(capCenterY - dotSize / 2.0)
            let dotX: CGFloat = 7.5

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            indicatorDot.frame = CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
            indicatorDot.cornerRadius = dotSize / 2.0
            CATransaction.commit()
        }
    }

    private func setupUI() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false

        if let l = visualEffectView.layer {
            l.cornerCurve = .continuous
            l.masksToBounds = true
            l.borderWidth = 0.5
        }
        addSubview(visualEffectView)
        NSLayoutConstraint.activate([
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // Optional status dot
        indicatorDot.frame = CGRect(x: 7.5, y: 6.0, width: 5.0, height: 5.0)
        indicatorDot.cornerRadius = 2.5
        indicatorDot.isHidden = !hasIndicatorDot
        visualEffectView.layer?.addSublayer(indicatorDot)

        // Monospaced text label
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(label)

        let lead = label.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: hasIndicatorDot ? 18 : 8)
        self.leadingConstraint = lead

        NSLayoutConstraint.activate([
            lead,
            label.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: visualEffectView.centerYAnchor),
            visualEffectView.heightAnchor.constraint(greaterThanOrEqualToConstant: 18)
        ])
    }

    private func updateLayoutConstraints() {
        leadingConstraint?.constant = hasIndicatorDot ? 18 : 8
        needsLayout = true
    }

    private func setupThemeObserver() {
        NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyTheme()
            }
        }
    }

    open func applyTheme() {
        let theme = ThemeManager.shared
        visualEffectView.appearance = theme.glassAppearance
        visualEffectView.layer?.backgroundColor = theme.wellBackgroundColor
        visualEffectView.layer?.borderColor = theme.pillBorderColor
        label.textColor = theme.primaryTextColor

        if theme.isDark {
            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.80)
            textShadow.shadowOffset = NSSize(width: 0, height: -1)
            textShadow.shadowBlurRadius = 2
            label.shadow = textShadow
        } else {
            label.shadow = nil
        }
    }
}
