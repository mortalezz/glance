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

    private let imageLayer = CALayer()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusPill = NSView()
    private var isHovered = false

    public init(data: FaceTileData) {
        self.faceIndex = data.index
        super.init(frame: .zero)
        setupUI(data: data)
    }

    public required init?(coder: NSCoder) {
        nil
    }

    private func setupUI(data: FaceTileData) {
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
        layer.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        // Face crop image layer
        imageLayer.frame = CGRect(x: 0, y: 18, width: 84, height: 74)
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.contents = data.image
        imageLayer.masksToBounds = true
        layer.addSublayer(imageLayer)

        // Top-left index badge
        let indexBadge = NSView()
        indexBadge.wantsLayer = true
        indexBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        indexBadge.layer?.cornerRadius = 5
        indexBadge.layer?.cornerCurve = .continuous
        indexBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indexBadge)

        badgeLabel.stringValue = "\(data.index)"
        badgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .white
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

        let isSharp = data.isEyeSharp
        let hasEyes = data.hasOpenEyes

        if isSharp && hasEyes {
            statusPill.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.35).cgColor
            statusLabel.stringValue = "👁️ Crisp"
            statusLabel.textColor = NSColor(srgbRed: 0.4, green: 1.0, blue: 0.5, alpha: 1.0)
        } else if !hasEyes {
            statusPill.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.40).cgColor
            statusLabel.stringValue = "⚠️ Squint"
            statusLabel.textColor = NSColor(srgbRed: 1.0, green: 0.8, blue: 0.3, alpha: 1.0)
        } else {
            statusPill.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
            statusLabel.stringValue = "👁️ Open"
            statusLabel.textColor = NSColor(srgbRed: 0.5, green: 0.8, blue: 1.0, alpha: 1.0)
        }

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

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.borderWidth = 2.0
        layer?.borderColor = NSColor.systemCyan.cgColor
        NSCursor.pointingHand.push()
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        NSCursor.pop()
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
    private let titleLabel = NSTextField(labelWithString: "👥 FACES")
    private let hintLabel = NSTextField(labelWithString: "Click to jump 100%")
    private let closeButton = NSButton()
    private let tilesStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No faces detected in frame")

    public private(set) var isPresented: Bool = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
        setupLayout()
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
            layer.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        }

        addSubview(visualEffectView)
        NSLayoutConstraint.activate([
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor)
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
        titleLabel.textColor = .white
        headerRow.addArrangedSubview(titleLabel)

        hintLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        hintLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
        headerRow.addArrangedSubview(hintLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(spacer)

        closeButton.title = "✕"
        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        closeButton.contentTintColor = NSColor(white: 0.70, alpha: 1.0)
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

        // Empty label
        emptyLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        emptyLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        emptyLabel.isHidden = true
        contentStack.addArrangedSubview(emptyLabel)
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

        if tiles.isEmpty {
            titleLabel.stringValue = "👥 FACES"
            hintLabel.stringValue = ""
            emptyLabel.isHidden = false
            tilesStack.isHidden = true
        } else {
            titleLabel.stringValue = "👥 FACES (\(tiles.count))"
            hintLabel.stringValue = "Click to jump 100%"
            emptyLabel.isHidden = true
            tilesStack.isHidden = false

            for tile in tiles {
                let tileView = FaceTileView(data: tile)
                tileView.onClick = { [weak self] in
                    self?.onFaceSelected?(tile.index)
                }
                tilesStack.addArrangedSubview(tileView)
            }
        }
        layoutSubtreeIfNeeded()
    }

    public func toggle() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    public func present() {
        guard !isPresented else { return }
        isPresented = true
        isHidden = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }
    }

    public func dismiss() {
        guard isPresented else { return }
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
