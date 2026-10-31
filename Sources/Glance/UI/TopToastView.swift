import AppKit

/// Floating top-center frosted glass dynamic toast banner for transient event and feedback messages
/// (e.g. Scene Leap, Burst Hero jump, Undo/Redo, Toggles, Boundary hits).
/// Completely decouples transient notifications from the bottom telemetry HUD to eliminate all layout jitter.
@MainActor
public final class TopToastView: NSView {
    public struct ToastPayload: Sendable, Equatable {
        public let message: String
        public let icon: String?
        public let shortcutHint: String?
        public let tintColor: NSColor?
        public let duration: TimeInterval

        public init(
            message: String,
            icon: String? = nil,
            shortcutHint: String? = nil,
            tintColor: NSColor? = nil,
            duration: TimeInterval = 1.6
        ) {
            self.message = message
            self.icon = icon
            self.shortcutHint = shortcutHint
            self.tintColor = tintColor
            self.duration = duration
        }
    }

    private let visualEffectView = NSVisualEffectView()
    private let scrimView = NSView()
    private let stackView = NSStackView()

    private let iconLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")

    private let shortcutPill = NSView()
    private let shortcutLabel = NSTextField(labelWithString: "")

    private var dismissTimer: Timer?
    private var currentPayload: ToastPayload?
    private var isDismissing: Bool = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        setupThemeObserver()
        applyTheme()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
        setupThemeObserver()
        applyTheme()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // Completely pass-through to underlying photos/panes
        return nil
    }

    private func setupView() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0.0

        // 1. Frosted Visual Effect Background
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14
        visualEffectView.layer?.cornerCurve = .continuous
        visualEffectView.layer?.borderWidth = 0.5
        visualEffectView.layer?.masksToBounds = true
        addSubview(visualEffectView)

        // 2. Subtle Darkening Scrim
        scrimView.translatesAutoresizingMaskIntoConstraints = false
        scrimView.wantsLayer = true
        visualEffectView.addSubview(scrimView)

        // 3. Horizontal Content Stack
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        visualEffectView.addSubview(stackView)

        // Icon
        iconLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        iconLabel.alignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(iconLabel)

        // Message
        messageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        messageLabel.alignment = .left
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stackView.addArrangedSubview(messageLabel)

        // Shortcut Pill [ ⌘Z ]
        shortcutPill.wantsLayer = true
        shortcutPill.layer?.cornerRadius = 5
        shortcutPill.layer?.cornerCurve = .continuous
        shortcutPill.layer?.borderWidth = 0.5
        shortcutPill.translatesAutoresizingMaskIntoConstraints = false

        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        shortcutLabel.alignment = .center
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutPill.addSubview(shortcutLabel)
        NSLayoutConstraint.activate([
            shortcutLabel.topAnchor.constraint(equalTo: shortcutPill.topAnchor, constant: 2),
            shortcutLabel.bottomAnchor.constraint(equalTo: shortcutPill.bottomAnchor, constant: -2),
            shortcutLabel.leadingAnchor.constraint(equalTo: shortcutPill.leadingAnchor, constant: 6),
            shortcutLabel.trailingAnchor.constraint(equalTo: shortcutPill.trailingAnchor, constant: -6)
        ])
        stackView.addArrangedSubview(shortcutPill)

        NSLayoutConstraint.activate([
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrimView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            scrimView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            scrimView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),

            stackView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor)
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

    private func applyTheme() {
        let theme = ThemeManager.shared
        let isDark = theme.isDark

        visualEffectView.appearance = theme.glassAppearance
        scrimView.layer?.backgroundColor = theme.scrimColor.cgColor

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.20)
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowBlurRadius = 22
        self.shadow = shadow

        if isDark {
            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
            textShadow.shadowOffset = NSSize(width: 0, height: -1)
            textShadow.shadowBlurRadius = 2
            messageLabel.shadow = textShadow

            messageLabel.textColor = .white
            shortcutLabel.textColor = NSColor.white.withAlphaComponent(0.90)
            shortcutPill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            shortcutPill.layer?.borderColor = NSColor.white.withAlphaComponent(0.24).cgColor
            visualEffectView.layer?.borderColor = currentPayload?.tintColor?.withAlphaComponent(0.70).cgColor
                ?? NSColor.white.withAlphaComponent(0.22).cgColor
        } else {
            messageLabel.shadow = nil
            messageLabel.textColor = NSColor(white: 0.12, alpha: 1.0)
            shortcutLabel.textColor = NSColor(white: 0.20, alpha: 1.0)
            shortcutPill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
            shortcutPill.layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor
            visualEffectView.layer?.borderColor = currentPayload?.tintColor?.withAlphaComponent(0.55).cgColor
                ?? NSColor.black.withAlphaComponent(0.14).cgColor
        }

        if let tint = currentPayload?.tintColor {
            visualEffectView.layer?.borderWidth = 1.0
            visualEffectView.layer?.borderColor = tint.withAlphaComponent(isDark ? 0.75 : 0.60).cgColor
        } else {
            visualEffectView.layer?.borderWidth = 0.5
        }
    }

    // MARK: - Presentation & Animation Physics

    /// Presents a dynamic toast at top-center.
    /// If a toast is already on screen, it fluidly retargets and updates in-place without jarring off-screen animation.
    public func present(_ payload: ToastPayload) {
        dismissTimer?.invalidate()
        dismissTimer = nil

        let wasVisible = (!isHidden && alphaValue > 0.1 && !isDismissing)
        self.currentPayload = payload

        // Update content
        if let icon = payload.icon, !icon.isEmpty {
            iconLabel.stringValue = icon
            iconLabel.isHidden = false
        } else {
            iconLabel.isHidden = true
        }

        messageLabel.stringValue = payload.message

        if let shortcut = payload.shortcutHint, !shortcut.isEmpty {
            shortcutLabel.stringValue = shortcut
            shortcutPill.isHidden = false
        } else {
            shortcutPill.isHidden = true
        }

        applyTheme()

        if wasVisible {
            // In-place retargeting: quick subtle scale pulse to acknowledge new message
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                self.layer?.transform = CATransform3DMakeScale(1.03, 1.03, 1.0)
            } completionHandler: {
                Task { @MainActor [weak self] in
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.10
                        context.allowsImplicitAnimation = true
                        self?.layer?.transform = CATransform3DIdentity
                    }
                }
            }
        } else {
            // Fresh entrance: spring slide-down from top
            isDismissing = false
            isHidden = false
            alphaValue = 0.0
            layer?.transform = CATransform3DMakeTranslation(0, 20, 0) // Shifted up towards bezel

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                self.animator().alphaValue = 1.0
                self.layer?.transform = CATransform3DIdentity
            }
        }

        // Schedule dismissal
        dismissTimer = Timer.scheduledTimer(withTimeInterval: payload.duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    public func dismiss(animated: Bool = true) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard !isHidden && alphaValue > 0.0 else { return }

        if !animated {
            alphaValue = 0.0
            isHidden = true
            layer?.transform = CATransform3DIdentity
            return
        }

        isDismissing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            context.allowsImplicitAnimation = true
            self.animator().alphaValue = 0.0
            self.layer?.transform = CATransform3DMakeTranslation(0, 16, 0)
        } completionHandler: {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isHidden = true
                self.isDismissing = false
                self.layer?.transform = CATransform3DIdentity
            }
        }
    }
}
