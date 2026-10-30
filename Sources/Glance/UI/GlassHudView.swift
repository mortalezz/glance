import AppKit

/// Model representation of metadata and status displayed within the frosted glass HUD.
public struct HudInfo: Sendable {
    public let currentIndex: Int
    public let totalCount: Int
    public let filename: String
    public let dimensions: String?
    public let fileSize: String?
    public let isRaw: Bool
    public let isStacked: Bool
    public let isDownscaled: Bool
    public let culling: CullingMetadata
    public let autoAdvance: Bool
    public let filterTitle: String?
    public let isZoomed: Bool
    public let errorMessage: String?
    public let exif: ExifMetadata?
    public let isSlideshow: Bool
    public let slideshowInterval: Double
    public let exportProgressText: String?

    public init(
        currentIndex: Int,
        totalCount: Int,
        filename: String,
        dimensions: String? = nil,
        fileSize: String? = nil,
        isRaw: Bool = false,
        isStacked: Bool = false,
        isDownscaled: Bool = false,
        culling: CullingMetadata = CullingMetadata(),
        autoAdvance: Bool = false,
        filterTitle: String? = nil,
        isZoomed: Bool = false,
        errorMessage: String? = nil,
        exif: ExifMetadata? = nil,
        isSlideshow: Bool = false,
        slideshowInterval: Double = 3.0,
        exportProgressText: String? = nil
    ) {
        self.currentIndex = currentIndex
        self.totalCount = totalCount
        self.filename = filename
        self.dimensions = dimensions
        self.fileSize = fileSize
        self.isRaw = isRaw
        self.isStacked = isStacked
        self.isDownscaled = isDownscaled
        self.culling = culling
        self.autoAdvance = autoAdvance
        self.filterTitle = filterTitle
        self.isZoomed = isZoomed
        self.errorMessage = errorMessage
        self.exif = exif
        self.isSlideshow = isSlideshow
        self.slideshowInterval = slideshowInterval
        self.exportProgressText = exportProgressText
    }
}

/// Interactive pill button displaying a Day / Night theme toggle icon.
@MainActor
final class ThemePillButton: NSView {
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 20),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13)
        ])

        toolTip = "Toggle Light / Dark Theme (T)"
        update(isDark: ThemeManager.shared.isDark)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateColors()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    func update(isDark: Bool) {
        // When in Dark mode, show Sun icon inviting switch to Light
        // When in Light mode, show Moon icon inviting switch to Dark
        let symbolName = isDark ? "sun.max.fill" : "moon.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Toggle Light/Dark Theme")?.withSymbolConfiguration(config) {
            iconView.image = img
        }
        updateColors()
    }

    private func updateColors() {
        let isDark = ThemeManager.shared.isDark
        if isDark {
            layer?.backgroundColor = isHovered
                ? NSColor.white.withAlphaComponent(0.24).cgColor
                : NSColor.white.withAlphaComponent(0.12).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
            iconView.contentTintColor = isHovered
                ? NSColor(calibratedRed: 1.0, green: 0.86, blue: 0.35, alpha: 1.0)
                : NSColor(white: 0.90, alpha: 1.0)
        } else {
            layer?.backgroundColor = isHovered
                ? NSColor.black.withAlphaComponent(0.14).cgColor
                : NSColor.black.withAlphaComponent(0.06).cgColor
            layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
            iconView.contentTintColor = isHovered
                ? NSColor(calibratedRed: 0.20, green: 0.35, blue: 0.75, alpha: 1.0)
                : NSColor(white: 0.20, alpha: 1.0)
        }
    }
}

/// Modern macOS frosted-glass HUD overlay container.
/// Displays index, filename, resolution, stars (★), picks/rejects, colors, culling stats, and theme toggle.
@MainActor
public final class GlassHudView: NSView {
    private let visualEffectView = NSVisualEffectView()
    private let scrimView = NSView()

    private let indexPill = NSView()
    private let indexLabel = NSTextField(labelWithString: "")

    private let pickBadge = NSView()
    private let pickLabel = NSTextField(labelWithString: "")

    private let colorBadge = NSView()
    private let colorLabel = NSTextField(labelWithString: "")

    private let ratingLabel = NSTextField(labelWithString: "")

    private let filenameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    private let rawBadge = NSView()
    private let rawLabel = NSTextField(labelWithString: "RAW")

    private let autoPill = NSView()
    private let autoLabel = NSTextField(labelWithString: "AUTO")

    private let filterPill = NSView()
    private let filterLabel = NSTextField(labelWithString: "")

    private let profilePill = NSView()
    private let profileLabel = NSTextField(labelWithString: "")

    private let zoomPill = NSView()
    private let zoomLabel = NSTextField(labelWithString: "100%")

    private let slideshowPill = NSView()
    private let slideshowLabel = NSTextField(labelWithString: "SLIDESHOW")

    private let exportPill = NSView()
    private let exportLabel = NSTextField(labelWithString: "")

    private let themeButton = ThemePillButton()

    private let stackView = NSStackView()
    private var lastInfo: HudInfo?

    private var fadeTimer: Timer?
    private var messageTimer: Timer?

    public var isPersistentlyVisible: Bool = false {
        didSet {
            if isPersistentlyVisible {
                fadeTimer?.invalidate()
                fadeIn()
            } else {
                scheduleFadeOut()
            }
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlassHierarchy()
        setupThemeObserver()
        applyTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGlassHierarchy()
        setupThemeObserver()
        applyTheme()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let ptInButton = themeButton.convert(point, from: self)
        if themeButton.bounds.contains(ptInButton) {
            return themeButton
        }
        return nil
    }

    public func handleMouseDown(at point: NSPoint) -> Bool {
        let ptInButton = themeButton.convert(point, from: self)
        if themeButton.bounds.contains(ptInButton) {
            ThemeManager.shared.toggleTheme()
            pulse()
            return true
        }
        return false
    }

    private func setupGlassHierarchy() {
        wantsLayer = true

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false

        if let effectLayer = visualEffectView.layer {
            effectLayer.cornerRadius = 16
            effectLayer.cornerCurve = .continuous
            effectLayer.masksToBounds = true
            effectLayer.borderWidth = 0.75
        }

        scrimView.wantsLayer = true
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

        setupSubviews()
    }

    private func setupSubviews() {
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        visualEffectView.addSubview(stackView)

        // 1. Index Pill [ 1 / 48 ]
        indexPill.wantsLayer = true
        indexPill.layer?.cornerRadius = 8
        indexPill.layer?.cornerCurve = .continuous
        indexPill.layer?.borderWidth = 0.5
        indexPill.translatesAutoresizingMaskIntoConstraints = false

        indexLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        indexLabel.alignment = .center
        indexLabel.translatesAutoresizingMaskIntoConstraints = false

        indexPill.addSubview(indexLabel)
        NSLayoutConstraint.activate([
            indexLabel.topAnchor.constraint(equalTo: indexPill.topAnchor, constant: 3),
            indexLabel.bottomAnchor.constraint(equalTo: indexPill.bottomAnchor, constant: -3),
            indexLabel.leadingAnchor.constraint(equalTo: indexPill.leadingAnchor, constant: 7),
            indexLabel.trailingAnchor.constraint(equalTo: indexPill.trailingAnchor, constant: -7)
        ])
        stackView.addArrangedSubview(indexPill)

        // 2. Pick / Reject Badge
        pickBadge.wantsLayer = true
        pickBadge.layer?.cornerRadius = 6
        pickBadge.layer?.cornerCurve = .continuous
        pickBadge.translatesAutoresizingMaskIntoConstraints = false

        pickLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        pickLabel.alignment = .center
        pickLabel.translatesAutoresizingMaskIntoConstraints = false

        pickBadge.addSubview(pickLabel)
        NSLayoutConstraint.activate([
            pickLabel.topAnchor.constraint(equalTo: pickBadge.topAnchor, constant: 2),
            pickLabel.bottomAnchor.constraint(equalTo: pickBadge.bottomAnchor, constant: -2),
            pickLabel.leadingAnchor.constraint(equalTo: pickBadge.leadingAnchor, constant: 6),
            pickLabel.trailingAnchor.constraint(equalTo: pickBadge.trailingAnchor, constant: -6)
        ])
        stackView.addArrangedSubview(pickBadge)

        // 2b. Color Label Badge (RED / YELLOW / GREEN / BLUE)
        colorBadge.wantsLayer = true
        colorBadge.layer?.cornerRadius = 6
        colorBadge.layer?.cornerCurve = .continuous
        colorBadge.translatesAutoresizingMaskIntoConstraints = false

        colorLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        colorLabel.alignment = .center
        colorLabel.translatesAutoresizingMaskIntoConstraints = false

        colorBadge.addSubview(colorLabel)
        NSLayoutConstraint.activate([
            colorLabel.topAnchor.constraint(equalTo: colorBadge.topAnchor, constant: 2),
            colorLabel.bottomAnchor.constraint(equalTo: colorBadge.bottomAnchor, constant: -2),
            colorLabel.leadingAnchor.constraint(equalTo: colorBadge.leadingAnchor, constant: 6),
            colorLabel.trailingAnchor.constraint(equalTo: colorBadge.trailingAnchor, constant: -6)
        ])
        stackView.addArrangedSubview(colorBadge)

        // 3. Star Rating (★ ★ ★ ☆ ☆)
        ratingLabel.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        ratingLabel.textColor = NSColor.systemYellow
        stackView.addArrangedSubview(ratingLabel)

        // 4. Filename
        filenameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.maximumNumberOfLines = 1
        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(filenameLabel)

        // 5. Metadata (Resolution / File Size)
        metaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stackView.addArrangedSubview(metaLabel)

        // 6. RAW / Stack Badge
        rawBadge.wantsLayer = true
        rawBadge.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.25).cgColor
        rawBadge.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.55).cgColor
        rawBadge.layer?.borderWidth = 0.5
        rawBadge.layer?.cornerRadius = 5
        rawBadge.layer?.cornerCurve = .continuous
        rawBadge.translatesAutoresizingMaskIntoConstraints = false

        rawLabel.font = NSFont.systemFont(ofSize: 9, weight: .heavy)
        rawLabel.textColor = NSColor.systemOrange
        rawLabel.alignment = .center
        rawLabel.translatesAutoresizingMaskIntoConstraints = false

        rawBadge.addSubview(rawLabel)
        NSLayoutConstraint.activate([
            rawLabel.topAnchor.constraint(equalTo: rawBadge.topAnchor, constant: 2),
            rawLabel.bottomAnchor.constraint(equalTo: rawBadge.bottomAnchor, constant: -2),
            rawLabel.leadingAnchor.constraint(equalTo: rawBadge.leadingAnchor, constant: 5),
            rawLabel.trailingAnchor.constraint(equalTo: rawBadge.trailingAnchor, constant: -5)
        ])
        stackView.addArrangedSubview(rawBadge)

        // 7. Auto-Advance Indicator (AUTO)
        autoPill.wantsLayer = true
        autoPill.layer?.backgroundColor = NSColor.systemCyan.withAlphaComponent(0.25).cgColor
        autoPill.layer?.borderColor = NSColor.systemCyan.withAlphaComponent(0.55).cgColor
        autoPill.layer?.borderWidth = 0.5
        autoPill.layer?.cornerRadius = 5
        autoPill.layer?.cornerCurve = .continuous
        autoPill.translatesAutoresizingMaskIntoConstraints = false

        autoLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        autoLabel.textColor = NSColor.systemCyan
        autoLabel.alignment = .center
        autoLabel.translatesAutoresizingMaskIntoConstraints = false

        autoPill.addSubview(autoLabel)
        NSLayoutConstraint.activate([
            autoLabel.topAnchor.constraint(equalTo: autoPill.topAnchor, constant: 2),
            autoLabel.bottomAnchor.constraint(equalTo: autoPill.bottomAnchor, constant: -2),
            autoLabel.leadingAnchor.constraint(equalTo: autoPill.leadingAnchor, constant: 5),
            autoLabel.trailingAnchor.constraint(equalTo: autoPill.trailingAnchor, constant: -5)
        ])
        stackView.addArrangedSubview(autoPill)

        // 8. Filter Active Pill
        filterPill.wantsLayer = true
        filterPill.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.25).cgColor
        filterPill.layer?.borderColor = NSColor.systemPurple.withAlphaComponent(0.55).cgColor
        filterPill.layer?.borderWidth = 0.5
        filterPill.layer?.cornerRadius = 5
        filterPill.layer?.cornerCurve = .continuous
        filterPill.translatesAutoresizingMaskIntoConstraints = false

        filterLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        filterLabel.textColor = NSColor.systemPurple
        filterLabel.alignment = .center
        filterLabel.translatesAutoresizingMaskIntoConstraints = false

        filterPill.addSubview(filterLabel)
        NSLayoutConstraint.activate([
            filterLabel.topAnchor.constraint(equalTo: filterPill.topAnchor, constant: 2),
            filterLabel.bottomAnchor.constraint(equalTo: filterPill.bottomAnchor, constant: -2),
            filterLabel.leadingAnchor.constraint(equalTo: filterPill.leadingAnchor, constant: 6),
            filterLabel.trailingAnchor.constraint(equalTo: filterPill.trailingAnchor, constant: -6)
        ])
        stackView.addArrangedSubview(filterPill)

        // Profile / Picture Control Pill
        profilePill.wantsLayer = true
        profilePill.layer?.backgroundColor = NSColor.systemIndigo.withAlphaComponent(0.25).cgColor
        profilePill.layer?.borderColor = NSColor.systemIndigo.withAlphaComponent(0.55).cgColor
        profilePill.layer?.borderWidth = 0.5
        profilePill.layer?.cornerRadius = 5
        profilePill.layer?.cornerCurve = .continuous
        profilePill.translatesAutoresizingMaskIntoConstraints = false

        profilePill.isHidden = true
        profileLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        profileLabel.textColor = NSColor.systemIndigo
        profileLabel.alignment = .center
        profileLabel.translatesAutoresizingMaskIntoConstraints = false

        profilePill.addSubview(profileLabel)
        NSLayoutConstraint.activate([
            profileLabel.topAnchor.constraint(equalTo: profilePill.topAnchor, constant: 2),
            profileLabel.bottomAnchor.constraint(equalTo: profilePill.bottomAnchor, constant: -2),
            profileLabel.leadingAnchor.constraint(equalTo: profilePill.leadingAnchor, constant: 6),
            profileLabel.trailingAnchor.constraint(equalTo: profilePill.trailingAnchor, constant: -6)
        ])
        stackView.addArrangedSubview(profilePill)

        // 9. Zoom 100% Indicator Pill
        zoomPill.wantsLayer = true
        zoomPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        zoomPill.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        zoomPill.layer?.borderWidth = 0.5
        zoomPill.layer?.cornerRadius = 5
        zoomPill.layer?.cornerCurve = .continuous
        zoomPill.translatesAutoresizingMaskIntoConstraints = false

        zoomLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        zoomLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        zoomLabel.alignment = .center
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false

        zoomPill.addSubview(zoomLabel)
        NSLayoutConstraint.activate([
            zoomLabel.topAnchor.constraint(equalTo: zoomPill.topAnchor, constant: 2),
            zoomLabel.bottomAnchor.constraint(equalTo: zoomPill.bottomAnchor, constant: -2),
            zoomLabel.leadingAnchor.constraint(equalTo: zoomPill.leadingAnchor, constant: 6),
            zoomLabel.trailingAnchor.constraint(equalTo: zoomPill.trailingAnchor, constant: -6)
        ])
        stackView.addArrangedSubview(zoomPill)

        // 10. Slideshow Mode Pill
        slideshowPill.wantsLayer = true
        slideshowPill.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.25).cgColor
        slideshowPill.layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.55).cgColor
        slideshowPill.layer?.borderWidth = 0.5
        slideshowPill.layer?.cornerRadius = 5
        slideshowPill.layer?.cornerCurve = .continuous
        slideshowPill.translatesAutoresizingMaskIntoConstraints = false

        slideshowPill.isHidden = true
        slideshowLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        slideshowLabel.textColor = NSColor.systemTeal
        slideshowLabel.alignment = .center
        slideshowLabel.translatesAutoresizingMaskIntoConstraints = false

        slideshowPill.addSubview(slideshowLabel)
        NSLayoutConstraint.activate([
            slideshowLabel.topAnchor.constraint(equalTo: slideshowPill.topAnchor, constant: 2),
            slideshowLabel.bottomAnchor.constraint(equalTo: slideshowPill.bottomAnchor, constant: -2),
            slideshowLabel.leadingAnchor.constraint(equalTo: slideshowPill.leadingAnchor, constant: 6),
            slideshowLabel.trailingAnchor.constraint(equalTo: slideshowPill.trailingAnchor, constant: -6)
        ])
        stackView.addArrangedSubview(slideshowPill)

        // 11. Export Progress Pill
        exportPill.wantsLayer = true
        exportPill.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.25).cgColor
        exportPill.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.55).cgColor
        exportPill.layer?.borderWidth = 0.5
        exportPill.layer?.cornerRadius = 5
        exportPill.layer?.cornerCurve = .continuous
        exportPill.translatesAutoresizingMaskIntoConstraints = false

        exportPill.isHidden = true
        exportLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        exportLabel.textColor = NSColor.systemGreen
        exportLabel.alignment = .center
        exportLabel.translatesAutoresizingMaskIntoConstraints = false

        exportPill.addSubview(exportLabel)
        NSLayoutConstraint.activate([
            exportLabel.topAnchor.constraint(equalTo: exportPill.topAnchor, constant: 2),
            exportLabel.bottomAnchor.constraint(equalTo: exportPill.bottomAnchor, constant: -2),
            exportLabel.leadingAnchor.constraint(equalTo: exportPill.leadingAnchor, constant: 6),
            exportLabel.trailingAnchor.constraint(equalTo: exportPill.trailingAnchor, constant: -6)
        ])
        stackView.addArrangedSubview(exportPill)

        // 12. Permanent Day / Night Theme Toggle Button
        themeButton.onClick = { [weak self] in
            ThemeManager.shared.toggleTheme()
            self?.pulse()
        }
        stackView.addArrangedSubview(themeButton)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor)
        ])
    }

    // MARK: - Theme Management

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

    private func applyTheme() {
        let theme = ThemeManager.shared
        visualEffectView.appearance = theme.glassAppearance
        scrimView.layer?.backgroundColor = theme.scrimColor.cgColor
        visualEffectView.layer?.borderColor = theme.glassBorderColor

        let shadow = NSShadow()
        shadow.shadowColor = theme.shadowColor
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.shadowBlurRadius = 16
        self.shadow = shadow

        // Typography & Shadow styling
        if theme.isDark {
            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.80)
            textShadow.shadowOffset = NSSize(width: 0, height: -1)
            textShadow.shadowBlurRadius = 2

            indexLabel.shadow = textShadow
            ratingLabel.shadow = textShadow
            filenameLabel.shadow = textShadow
            metaLabel.shadow = textShadow
        } else {
            // Clean crisp text without muddy drop shadows in Light glass
            indexLabel.shadow = nil
            ratingLabel.shadow = nil
            filenameLabel.shadow = nil
            metaLabel.shadow = nil
        }

        filenameLabel.textColor = theme.primaryTextColor
        metaLabel.textColor = theme.secondaryTextColor
        indexLabel.textColor = theme.primaryTextColor
        indexPill.layer?.backgroundColor = theme.pillBackgroundColor
        indexPill.layer?.borderColor = theme.pillBorderColor

        themeButton.update(isDark: theme.isDark)
    }

    public override func layout() {
        super.layout()
        updateMask()
    }

    private func updateMask() {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        maskImage.capInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        maskImage.resizingMode = .stretch
        visualEffectView.maskImage = maskImage
    }

    /// Updates the HUD contents with culling indicators.
    public func update(with info: HudInfo) {
        self.lastInfo = info
        messageTimer?.invalidate()
        messageTimer = nil
        renderInfo(info)
        pulse()
    }

    /// Restores the last active photo metadata (clearing any transient status messages)
    public func restoreLastInfo() {
        messageTimer?.invalidate()
        messageTimer = nil
        guard let info = lastInfo else { return }
        renderInfo(info)
    }

    private func renderInfo(_ info: HudInfo) {
        if info.totalCount > 0 {
            indexLabel.stringValue = "\(info.currentIndex + 1) / \(info.totalCount)"
            indexPill.isHidden = false
        } else {
            indexPill.isHidden = true
        }

        // Culling: Pick / Reject
        switch info.culling.pick {
        case .pick:
            pickLabel.stringValue = "PICK"
            pickLabel.textColor = NSColor.systemGreen
            pickBadge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.25).cgColor
            pickBadge.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.6).cgColor
            pickBadge.layer?.borderWidth = 0.5
            pickBadge.isHidden = false
        case .reject:
            pickLabel.stringValue = "REJECT"
            pickLabel.textColor = NSColor.systemRed
            pickBadge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
            pickBadge.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor
            pickBadge.layer?.borderWidth = 0.5
            pickBadge.isHidden = false
        case .unflagged:
            pickBadge.isHidden = true
        }

        // Culling: Color Label
        switch info.culling.color {
        case .red:
            colorLabel.stringValue = "RED"
            colorLabel.textColor = NSColor.systemRed
            colorBadge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.25).cgColor
            colorBadge.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.6).cgColor
            colorBadge.layer?.borderWidth = 0.5
            colorBadge.isHidden = false
        case .yellow:
            colorLabel.stringValue = "YELLOW"
            colorLabel.textColor = NSColor.systemYellow
            colorBadge.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.25).cgColor
            colorBadge.layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.6).cgColor
            colorBadge.layer?.borderWidth = 0.5
            colorBadge.isHidden = false
        case .green:
            colorLabel.stringValue = "GREEN"
            colorLabel.textColor = NSColor.systemGreen
            colorBadge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.25).cgColor
            colorBadge.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.6).cgColor
            colorBadge.layer?.borderWidth = 0.5
            colorBadge.isHidden = false
        case .blue:
            colorLabel.stringValue = "BLUE"
            colorLabel.textColor = NSColor.systemBlue
            colorBadge.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
            colorBadge.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
            colorBadge.layer?.borderWidth = 0.5
            colorBadge.isHidden = false
        case .none:
            colorBadge.isHidden = true
        }

        // Culling: Star Rating
        if info.culling.rating > 0 {
            let stars = String(repeating: "★", count: info.culling.rating) + String(repeating: "☆", count: 5 - info.culling.rating)
            ratingLabel.stringValue = stars
            ratingLabel.isHidden = false
        } else {
            ratingLabel.isHidden = true
        }

        filenameLabel.stringValue = info.filename
        filenameLabel.textColor = ThemeManager.shared.primaryTextColor

        // Auto-advance indicator
        autoPill.isHidden = !info.autoAdvance

        // Filter active indicator
        if let filter = info.filterTitle {
            filterLabel.stringValue = filter.uppercased()
            filterPill.isHidden = false
        } else {
            filterPill.isHidden = true
        }

        if let error = info.errorMessage {
            metaLabel.stringValue = error
            metaLabel.textColor = NSColor.systemRed
            rawBadge.isHidden = true
        } else {
            var parts: [String] = []
            if let exp = info.exif?.exposureSummary, !exp.isEmpty {
                parts.append(exp)
            }
            if let dim = info.dimensions {
                parts.append(dim)
            }
            if let size = info.fileSize {
                parts.append(size)
            }
            metaLabel.stringValue = parts.joined(separator: "  •  ")
            metaLabel.textColor = ThemeManager.shared.secondaryTextColor

            // RAW / Stack Badge
            if info.isStacked {
                rawLabel.stringValue = "RAW + JPG"
                rawBadge.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.25).cgColor
                rawBadge.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.55).cgColor
                rawBadge.isHidden = false
            } else if info.isRaw {
                rawLabel.stringValue = "RAW"
                rawBadge.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.25).cgColor
                rawBadge.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.55).cgColor
                rawBadge.isHidden = false
            } else {
                rawBadge.isHidden = true
            }
        }

        // Profile Pill
        if let prof = info.culling.cameraProfile, prof != .asShot {
            profileLabel.stringValue = prof.displayName.uppercased()
            profilePill.isHidden = false
        } else {
            profilePill.isHidden = true
        }

        // 100% Zoom Pill
        zoomPill.isHidden = !info.isZoomed

        // Slideshow Mode Pill
        slideshowPill.isHidden = !info.isSlideshow
        if info.isSlideshow {
            slideshowLabel.stringValue = "SLIDESHOW \(Int(info.slideshowInterval))s"
        }

        // Export Progress Pill
        if let expText = info.exportProgressText {
            exportLabel.stringValue = expText
            exportPill.isHidden = false
        } else {
            exportPill.isHidden = true
        }
    }

    /// Updates only the slideshow status and interval badge without clearing other metadata
    public func updateSlideshowState(isActive: Bool, interval: Double) {
        slideshowPill.isHidden = !isActive
        if isActive {
            slideshowLabel.stringValue = "SLIDESHOW \(Int(interval))s"
        }
        if let current = lastInfo {
            let updated = HudInfo(
                currentIndex: current.currentIndex,
                totalCount: current.totalCount,
                filename: current.filename,
                dimensions: current.dimensions,
                fileSize: current.fileSize,
                isRaw: current.isRaw,
                isStacked: current.isStacked,
                isDownscaled: current.isDownscaled,
                culling: current.culling,
                autoAdvance: current.autoAdvance,
                filterTitle: current.filterTitle,
                isZoomed: current.isZoomed,
                errorMessage: current.errorMessage,
                exif: current.exif,
                isSlideshow: isActive,
                slideshowInterval: interval,
                exportProgressText: current.exportProgressText
            )
            self.lastInfo = updated
        }
        pulse()
    }

    /// Updates only the zoom status without clearing or re-rendering other photo metadata
    public func updateZoomState(_ isZoomed: Bool) {
        zoomPill.isHidden = !isZoomed
        if let current = lastInfo {
            let updated = HudInfo(
                currentIndex: current.currentIndex,
                totalCount: current.totalCount,
                filename: current.filename,
                dimensions: current.dimensions,
                fileSize: current.fileSize,
                isRaw: current.isRaw,
                isStacked: current.isStacked,
                isDownscaled: current.isDownscaled,
                culling: current.culling,
                autoAdvance: current.autoAdvance,
                filterTitle: current.filterTitle,
                isZoomed: isZoomed,
                errorMessage: current.errorMessage
            )
            self.lastInfo = updated
        }
        pulse()
    }

    /// Displays a transient status message (e.g. toggle confirmation), which reverts back to original photo info after timeout.
    public func showMessage(_ message: String, duration: TimeInterval = 2.0) {
        messageTimer?.invalidate()
        fadeTimer?.invalidate()

        indexPill.isHidden = true
        pickBadge.isHidden = true
        colorBadge.isHidden = true
        ratingLabel.isHidden = true
        rawBadge.isHidden = true
        autoPill.isHidden = true
        filterPill.isHidden = true
        profilePill.isHidden = true
        zoomPill.isHidden = true
        slideshowPill.isHidden = true
        exportPill.isHidden = true

        metaLabel.stringValue = ""
        filenameLabel.stringValue = message
        filenameLabel.textColor = ThemeManager.shared.primaryTextColor

        fadeIn()

        messageTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.restoreLastInfo()
                if !self.isPersistentlyVisible {
                    self.scheduleFadeOut()
                }
            }
        }
    }

    public func pulse() {
        fadeIn()
        if !isPersistentlyVisible && messageTimer == nil {
            scheduleFadeOut()
        }
    }

    public func togglePersistent() {
        isPersistentlyVisible.toggle()
    }

    private func fadeIn() {
        fadeTimer?.invalidate()
        guard alphaValue < 1.0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1.0
        }
    }

    private func scheduleFadeOut() {
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isPersistentlyVisible else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.4
                    self.animator().alphaValue = 0.0
                } completionHandler: {
                    Task { @MainActor [weak self] in
                        self?.restoreLastInfo()
                    }
                }
            }
        }
    }

    deinit {
        fadeTimer?.invalidate()
        messageTimer?.invalidate()
    }
}
