import AppKit
import CoreGraphics

public struct FaceTileData: Sendable {
    public let index: Int
    public let image: CGImage
    public let eyeCenterNormalized: CGPoint
    public let isEyeSharp: Bool
    public let hasOpenEyes: Bool
    public let confidence: Float

    public init(
        index: Int,
        image: CGImage,
        eyeCenterNormalized: CGPoint,
        isEyeSharp: Bool = true,
        hasOpenEyes: Bool = true,
        confidence: Float = 1.0
    ) {
        self.index = index
        self.image = image
        self.eyeCenterNormalized = eyeCenterNormalized
        self.isEyeSharp = isEyeSharp
        self.hasOpenEyes = hasOpenEyes
        self.confidence = confidence
    }
}

/// Interactive individual face & eye inspection card.
public final class FaceTileView: NSView {
    public let faceIndex: Int
    public var onClick: (() -> Void)?
    public private(set) var isActiveZoom: Bool = false
    private var isHovered: Bool = false

    private let data: FaceTileData
    private let imageLayer = CALayer()
    private let indexBadge = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusPill = NSView()

    public init(data: FaceTileData) {
        self.faceIndex = data.index
        self.data = data
        super.init(frame: .zero)
        setupUI()
        applyTheme()
    }

    public required init?(coder: NSCoder) {
        nil
    }

    private func setupUI() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 84),
            heightAnchor.constraint(equalToConstant: 92)
        ])

        guard let layer = self.layer else { return }
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1.0

        // Face crop image layer
        imageLayer.frame = CGRect(x: 0, y: 18, width: 84, height: 74)
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.contents = data.image
        imageLayer.masksToBounds = true
        layer.addSublayer(imageLayer)

        // Top-left index badge
        indexBadge.wantsLayer = true
        indexBadge.layer?.cornerRadius = 5
        indexBadge.layer?.cornerCurve = .continuous
        indexBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indexBadge)

        badgeLabel.stringValue = "\(data.index)"
        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        indexBadge.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            indexBadge.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            indexBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            indexBadge.heightAnchor.constraint(equalToConstant: 16),
            indexBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            badgeLabel.centerXAnchor.constraint(equalTo: indexBadge.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: indexBadge.centerYAnchor)
        ])

        // Bottom status pill (Focus / Eyes)
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 4
        statusPill.layer?.cornerCurve = .continuous
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusPill)

        statusLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            statusPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            statusPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            statusPill.heightAnchor.constraint(equalToConstant: 16),
            statusLabel.centerXAnchor.constraint(equalTo: statusPill.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor)
        ])

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    public func setActiveZoom(_ active: Bool) {
        isActiveZoom = active
        updateBorder()
    }

    private func updateBorder() {
        if isActiveZoom {
            layer?.borderWidth = 2.0
            layer?.borderColor = NSColor.systemCyan.cgColor
        } else if isHovered {
            layer?.borderWidth = 2.0
            layer?.borderColor = NSColor.systemCyan.cgColor
        } else {
            layer?.borderWidth = 1.0
            layer?.borderColor = ThemeManager.shared.pillBorderColor
        }
    }

    public func applyTheme() {
        let theme = ThemeManager.shared
        let isDark = theme.isDark

        updateBorder()

        indexBadge.layer?.backgroundColor = isDark
            ? NSColor.black.withAlphaComponent(0.70).cgColor
            : NSColor.white.withAlphaComponent(0.85).cgColor
        badgeLabel.textColor = isDark ? .white : NSColor(white: 0.15, alpha: 1.0)

        let isSharp = data.isEyeSharp
        let hasEyes = data.hasOpenEyes

        if isSharp && hasEyes {
            statusPill.layer?.backgroundColor = isDark
                ? NSColor.systemGreen.withAlphaComponent(0.35).cgColor
                : NSColor.systemGreen.withAlphaComponent(0.20).cgColor
            statusLabel.stringValue = "👁️ Crisp"
            statusLabel.textColor = isDark
                ? NSColor(srgbRed: 0.4, green: 1.0, blue: 0.5, alpha: 1.0)
                : NSColor.systemGreen
        } else if !hasEyes {
            statusPill.layer?.backgroundColor = isDark
                ? NSColor.systemOrange.withAlphaComponent(0.40).cgColor
                : NSColor.systemOrange.withAlphaComponent(0.25).cgColor
            statusLabel.stringValue = "⚠️ Squint"
            statusLabel.textColor = isDark
                ? NSColor(srgbRed: 1.0, green: 0.8, blue: 0.3, alpha: 1.0)
                : NSColor.systemOrange
        } else {
            statusPill.layer?.backgroundColor = isDark
                ? NSColor.systemBlue.withAlphaComponent(0.35).cgColor
                : NSColor.systemBlue.withAlphaComponent(0.20).cgColor
            statusLabel.stringValue = "👁️ Open"
            statusLabel.textColor = isDark
                ? NSColor(srgbRed: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)
                : NSColor.systemBlue
        }
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBorder()
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBorder()
    }

    public override func mouseDown(with event: NSEvent) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        onClick?()
    }
}

/// Floating Apple HIG Frosted Glass Inspection Overlay for all detected faces.
/// Inspired by Narrative Select: allows instant simultaneous critical eye sharpness inspection.
public final class FaceLoupeOverlayView: NSView {
    public var onFaceSelected: ((Int) -> Void)?
    public var onClose: (() -> Void)?

    private let visualEffectView = NSVisualEffectView()
    private let scrimView = NSView()
    private let titleLabel = NSTextField(labelWithString: "👥 FACES")
    private let hintLabel = NSTextField(labelWithString: "Click to toggle 100%")
    public private(set) var activeFaceIndex: Int? = nil
    private let closeButton = NSButton()
    private let tilesStack = NSStackView()

    public private(set) var isPresented: Bool = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
        setupLayout()
        setupThemeObserver()
        applyTheme()
    }

    public required init?(coder: NSCoder) {
        nil
    }

    private func setupGlass() {
        wantsLayer = true
        alphaValue = 0.0
        isHidden = true

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false

        if let layer = visualEffectView.layer {
            layer.cornerRadius = 14
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.borderWidth = 0.5
        }

        addSubview(visualEffectView)
        NSLayoutConstraint.activate([
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        scrimView.wantsLayer = true
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(scrimView)
        NSLayoutConstraint.activate([
            scrimView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor)
        ])
    }

    private func setupLayout() {
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -12),
            contentStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -14)
        ])

        // Header Row
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        headerRow.addArrangedSubview(titleLabel)

        hintLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        headerRow.addArrangedSubview(hintLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(spacer)

        closeButton.title = "✕"
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        headerRow.addArrangedSubview(closeButton)

        contentStack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        // Tiles Row
        tilesStack.orientation = .horizontal
        tilesStack.alignment = .centerY
        tilesStack.spacing = 10
        tilesStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(tilesStack)


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

    public func applyTheme() {
        let theme = ThemeManager.shared
        visualEffectView.appearance = theme.glassAppearance
        scrimView.layer?.backgroundColor = theme.scrimColor.cgColor
        visualEffectView.layer?.borderColor = theme.glassBorderColor

        let shadow = NSShadow()
        shadow.shadowColor = theme.shadowColor
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowBlurRadius = 18
        self.shadow = shadow

        titleLabel.textColor = theme.primaryTextColor
        hintLabel.textColor = theme.secondaryTextColor
        closeButton.contentTintColor = theme.secondaryTextColor

        for subview in tilesStack.arrangedSubviews {
            if let tile = subview as? FaceTileView {
                tile.applyTheme()
            }
        }
    }

    @objc private func handleClose() {
        onClose?()
        dismiss()
    }

    public func update(with tiles: [FaceTileData]) {
        for sub in tilesStack.arrangedSubviews {
            tilesStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        activeFaceIndex = nil
        if tiles.isEmpty {
            titleLabel.stringValue = "👥 FACES"
            hintLabel.stringValue = ""
            tilesStack.isHidden = true
            dismiss()
        } else {
            titleLabel.stringValue = "👥 FACES (\(tiles.count))"
            hintLabel.stringValue = "Click to toggle 100%"
            tilesStack.isHidden = false

            for tile in tiles {
                let tileView = FaceTileView(data: tile)
                tileView.onClick = { [weak self] in
                    self?.onFaceSelected?(tile.index)
                }
                tileView.applyTheme()
                tilesStack.addArrangedSubview(tileView)
            }
        }
        layoutSubtreeIfNeeded()
    }

    public func setActiveFaceIndex(_ index: Int?) {
        activeFaceIndex = index
        for sub in tilesStack.arrangedSubviews {
            if let tile = sub as? FaceTileView {
                tile.setActiveZoom(tile.faceIndex == index)
            }
        }
        if index != nil {
            hintLabel.stringValue = "Click to unzoom"
        } else {
            hintLabel.stringValue = "Click to toggle 100%"
        }
    }

    public func toggle() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    public func present() {
        guard !tilesStack.arrangedSubviews.isEmpty else {
            dismiss()
            return
        }
        guard !isPresented else { return }
        isPresented = true
        isHidden = false
        applyTheme()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    public func dismiss() {
        guard isPresented else {
            isHidden = true
            alphaValue = 0.0
            return
        }
        isPresented = false

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, !self.isPresented else { return }
                self.isHidden = true
            }
        })
    }
}
