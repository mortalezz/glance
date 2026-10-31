import AppKit

/// Model info passed to each split compare badge pane.
public struct SplitPaneInfo: Sendable {
    public let slot: Int // 1 or 2
    public let filename: String
    public let pick: PickStatus
    public let rating: Int
    public let color: ColorLabel
    public let isChampion: Bool
    public let isChallenger: Bool
    public let isPairScouting: Bool
    public let aestheticScore: AestheticScoreResult?
    public let burstDescription: String?

    public init(
        slot: Int,
        filename: String,
        pick: PickStatus,
        rating: Int = 0,
        color: ColorLabel = .none,
        isChampion: Bool = false,
        isChallenger: Bool = false,
        isPairScouting: Bool = false,
        aestheticScore: AestheticScoreResult? = nil,
        burstDescription: String? = nil
    ) {
        self.slot = slot
        self.filename = filename
        self.pick = pick
        self.rating = rating
        self.color = color
        self.isChampion = isChampion
        self.isChallenger = isChallenger
        self.isPairScouting = isPairScouting
        self.aestheticScore = aestheticScore
        self.burstDescription = burstDescription
    }
}

/// Frosted glass floating pill badge labeling panes in 2-UP Split Compare mode (e.g. "[ 1 ] DSC_3088.NEF  ✨ 8.9 BEST  👑 CHAMPION").
@MainActor
public final class SplitPaneBadgeView: NSView {
    private let visualEffectView = NSVisualEffectView()
    private let scrimView = NSView()
    private let stackView = NSStackView()

    // 1. Keycap Pill: [ 1 ] or [ 2 ]
    private let keycapPill = NSView()
    private let keycapLabel = NSTextField(labelWithString: "1")

    // 2. Filename Label
    private let filenameLabel = NSTextField(labelWithString: "")

    // 3. Apple Vision Aesthetic Score Pill: ✨ 8.9 BEST
    private let aestheticPill = NSView()
    private let aestheticLabel = NSTextField(labelWithString: "")

    // 3b. Apple Neural Engine Scene / Burst Pill: BURST (Δ 0.3s)
    private let burstPill = NSView()
    private let burstLabel = NSTextField(labelWithString: "")

    // 4. Status Pill: 👑 CHAMPION / CHALLENGER / ✓ PICK / ✕ REJECT / PRESS 1
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")

    public let slot: Int
    private var currentInfo: SplitPaneInfo?
    private var currentAestheticScore: AestheticScoreResult?

    public init(slot: Int) {
        self.slot = slot
        super.init(frame: .zero)
        setupView()
        setupThemeObserver()
    }

    required init?(coder: NSCoder) {
        self.slot = 1
        super.init(coder: coder)
        setupView()
        setupThemeObserver()
    }

    /// Completely transparent to mouse clicks so user can click anywhere in the window to zoom in/out
    public override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    private func setupView() {
        wantsLayer = true
        // Allow SlideView.updateLayerLayout to frame-position the badge without Auto Layout solver fighting
        translatesAutoresizingMaskIntoConstraints = true

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false

        if let effectLayer = visualEffectView.layer {
            effectLayer.cornerRadius = 10
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

        // Soft floating HUD shadow
        let shadow = NSShadow()
        shadow.shadowColor = ThemeManager.shared.shadowColor
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 14
        self.shadow = shadow

        // Stack View
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        visualEffectView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor)
        ])

        // 1. Keycap Pill setup
        keycapPill.wantsLayer = true
        keycapPill.layer?.cornerRadius = 6
        keycapPill.layer?.cornerCurve = .continuous
        keycapPill.layer?.borderWidth = 0.5
        keycapPill.translatesAutoresizingMaskIntoConstraints = false

        keycapLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        keycapLabel.alignment = .center
        keycapLabel.translatesAutoresizingMaskIntoConstraints = false
        keycapLabel.stringValue = "\(slot)"

        keycapPill.addSubview(keycapLabel)
        NSLayoutConstraint.activate([
            keycapLabel.topAnchor.constraint(equalTo: keycapPill.topAnchor, constant: 2),
            keycapLabel.bottomAnchor.constraint(equalTo: keycapPill.bottomAnchor, constant: -2),
            keycapLabel.leadingAnchor.constraint(equalTo: keycapPill.leadingAnchor, constant: 7),
            keycapLabel.trailingAnchor.constraint(equalTo: keycapPill.trailingAnchor, constant: -7)
        ])
        stackView.addArrangedSubview(keycapPill)

        // 2. Filename Label setup
        filenameLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.maximumNumberOfLines = 1
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        filenameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stackView.addArrangedSubview(filenameLabel)

        // 3. Aesthetic Score Pill setup
        aestheticPill.wantsLayer = true
        aestheticPill.layer?.cornerRadius = 6
        aestheticPill.layer?.cornerCurve = .continuous
        aestheticPill.layer?.borderWidth = 0.5
        aestheticPill.translatesAutoresizingMaskIntoConstraints = false
        aestheticPill.isHidden = true

        aestheticLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        aestheticLabel.alignment = .center
        aestheticLabel.translatesAutoresizingMaskIntoConstraints = false

        aestheticPill.addSubview(aestheticLabel)
        NSLayoutConstraint.activate([
            aestheticLabel.topAnchor.constraint(equalTo: aestheticPill.topAnchor, constant: 2),
            aestheticLabel.bottomAnchor.constraint(equalTo: aestheticPill.bottomAnchor, constant: -2),
            aestheticLabel.leadingAnchor.constraint(equalTo: aestheticPill.leadingAnchor, constant: 6),
            aestheticLabel.trailingAnchor.constraint(equalTo: aestheticPill.trailingAnchor, constant: -6)
        ])
        stackView.addArrangedSubview(aestheticPill)

        // 3b. ANE Scene / Burst Pill setup
        burstPill.wantsLayer = true
        burstPill.layer?.cornerRadius = 6
        burstPill.layer?.cornerCurve = .continuous
        burstPill.layer?.borderWidth = 0.5
        burstPill.translatesAutoresizingMaskIntoConstraints = false
        burstPill.isHidden = true

        burstLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        burstLabel.alignment = .center
        burstLabel.translatesAutoresizingMaskIntoConstraints = false

        burstPill.addSubview(burstLabel)
        NSLayoutConstraint.activate([
            burstLabel.topAnchor.constraint(equalTo: burstPill.topAnchor, constant: 2),
            burstLabel.bottomAnchor.constraint(equalTo: burstPill.bottomAnchor, constant: -2),
            burstLabel.leadingAnchor.constraint(equalTo: burstPill.leadingAnchor, constant: 5),
            burstLabel.trailingAnchor.constraint(equalTo: burstPill.trailingAnchor, constant: -5)
        ])
        stackView.addArrangedSubview(burstPill)

        // 4. Status Pill setup
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 6
        statusPill.layer?.cornerCurve = .continuous
        statusPill.layer?.borderWidth = 0.5
        statusPill.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statusPill.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: statusPill.topAnchor, constant: 2),
            statusLabel.bottomAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: -2),
            statusLabel.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -6)
        ])
        stackView.addArrangedSubview(statusPill)

        updateTheme()
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

    public func update(with info: SplitPaneInfo?) {
        self.currentInfo = info
        guard let info = info else {
            isHidden = true
            return
        }

        isHidden = false
        keycapLabel.stringValue = "\(info.slot)"
        filenameLabel.stringValue = info.filename
        self.currentAestheticScore = info.aestheticScore

        updateTheme()
    }

    /// Dynamically updates the burst / scene pill description
    public func updateBurstDescription(_ desc: String?) {
        if let current = currentInfo {
            self.currentInfo = SplitPaneInfo(
                slot: current.slot,
                filename: current.filename,
                pick: current.pick,
                rating: current.rating,
                color: current.color,
                isChampion: current.isChampion,
                isChallenger: current.isChallenger,
                isPairScouting: current.isPairScouting,
                aestheticScore: current.aestheticScore,
                burstDescription: desc
            )
        }
        updateTheme()
        if desc != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                burstPill.animator().isHidden = false
            }
        }
    }

    /// Dynamically updates the aesthetic score independently as soon as background Vision computation finishes
    public func updateAestheticScore(_ score: AestheticScoreResult?) {
        self.currentAestheticScore = score
        updateTheme()
        if score != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                aestheticPill.animator().isHidden = false
            }
        }
    }

    public func updateTheme() {
        let theme = ThemeManager.shared
        let isDark = theme.isDark

        visualEffectView.material = .hudWindow
        visualEffectView.appearance = theme.glassAppearance
        visualEffectView.layer?.borderColor = theme.glassBorderColor
        scrimView.layer?.backgroundColor = theme.scrimColor.cgColor

        let shadow = NSShadow()
        shadow.shadowColor = theme.shadowColor
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 14
        self.shadow = shadow

        filenameLabel.textColor = theme.primaryTextColor

        // Keycap appearance
        if slot == 1 {
            // Teal / Cyan for Slot 1
            keycapPill.layer?.backgroundColor = isDark
                ? NSColor(srgbRed: 0.15, green: 0.50, blue: 0.70, alpha: 0.85).cgColor
                : NSColor(srgbRed: 0.10, green: 0.55, blue: 0.75, alpha: 0.88).cgColor
            keycapPill.layer?.borderColor = NSColor(srgbRed: 0.30, green: 0.75, blue: 0.95, alpha: 0.50).cgColor
            keycapLabel.textColor = .white
        } else {
            // Amber / Orange for Slot 2
            keycapPill.layer?.backgroundColor = isDark
                ? NSColor(srgbRed: 0.85, green: 0.45, blue: 0.15, alpha: 0.85).cgColor
                : NSColor(srgbRed: 0.90, green: 0.50, blue: 0.15, alpha: 0.88).cgColor
            keycapPill.layer?.borderColor = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.35, alpha: 0.50).cgColor
            keycapLabel.textColor = .white
        }

        guard let info = currentInfo else { return }

        let starSuffix = info.rating > 0 ? " ★\(info.rating)" : ""

        // Status badge: Handle King-of-the-Hill vs Pair Scouting
        if info.isChampion {
            statusLabel.stringValue = "👑 CHAMPION" + starSuffix
            statusLabel.textColor = .white
            statusPill.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.65, blue: 0.35, alpha: 0.90).cgColor
            statusPill.layer?.borderColor = NSColor(srgbRed: 0.20, green: 0.85, blue: 0.45, alpha: 0.60).cgColor
            statusPill.isHidden = false
        } else if info.isChallenger {
            statusLabel.stringValue = "CHALLENGER" + starSuffix
            statusLabel.textColor = .white
            statusPill.layer?.backgroundColor = NSColor(srgbRed: 0.20, green: 0.45, blue: 0.85, alpha: 0.85).cgColor
            statusPill.layer?.borderColor = NSColor(srgbRed: 0.40, green: 0.70, blue: 1.0, alpha: 0.50).cgColor
            statusPill.isHidden = false
        } else {
            switch info.pick {
            case .pick:
                statusLabel.stringValue = "✓ PICK" + starSuffix
                statusLabel.textColor = .white
                statusPill.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.65, blue: 0.35, alpha: 0.90).cgColor
                statusPill.layer?.borderColor = NSColor(srgbRed: 0.20, green: 0.85, blue: 0.45, alpha: 0.60).cgColor
                statusPill.isHidden = false

            case .reject:
                statusLabel.stringValue = "✕ REJECT" + starSuffix
                statusLabel.textColor = .white
                statusPill.layer?.backgroundColor = NSColor(srgbRed: 0.82, green: 0.22, blue: 0.22, alpha: 0.85).cgColor
                statusPill.layer?.borderColor = NSColor(srgbRed: 0.95, green: 0.35, blue: 0.35, alpha: 0.50).cgColor
                statusPill.isHidden = false

            case .unflagged:
                let starPrefix = info.rating > 0 ? "★\(info.rating) • " : ""
                statusLabel.stringValue = starPrefix + "PRESS \(info.slot)"
                statusLabel.textColor = theme.secondaryTextColor
                statusPill.layer?.backgroundColor = theme.pillBackgroundColor
                statusPill.layer?.borderColor = theme.pillBorderColor
                statusPill.isHidden = false
            }
        }

        // Burst / Scene Pill
        if let burst = info.burstDescription {
            burstLabel.stringValue = burst
            burstLabel.textColor = isDark ? NSColor.systemTeal : NSColor(srgbRed: 0.0, green: 0.52, blue: 0.58, alpha: 1.0)
            burstPill.layer?.backgroundColor = isDark
                ? NSColor.systemTeal.withAlphaComponent(0.22).cgColor
                : NSColor.systemTeal.withAlphaComponent(0.12).cgColor
            burstPill.layer?.borderColor = isDark
                ? NSColor.systemTeal.withAlphaComponent(0.50).cgColor
                : NSColor.systemTeal.withAlphaComponent(0.35).cgColor
            burstPill.isHidden = false
        } else {
            burstPill.isHidden = true
        }

        // Aesthetic Score Pill presentation (unified with GlassHudView)
        if let score = currentAestheticScore ?? info.aestheticScore {
            if score.isWinner || score.score >= 8.5 {
                aestheticLabel.stringValue = "✨ \(score.formattedScore) BEST"
                aestheticLabel.textColor = isDark ? NSColor.white : NSColor(srgbRed: 0.82, green: 0.58, blue: 0.10, alpha: 1.0)
                aestheticPill.layer?.backgroundColor = isDark
                    ? NSColor(srgbRed: 0.85, green: 0.65, blue: 0.12, alpha: 0.85).cgColor
                    : NSColor(srgbRed: 0.95, green: 0.82, blue: 0.35, alpha: 0.30).cgColor
                aestheticPill.layer?.borderColor = isDark
                    ? NSColor(srgbRed: 1.0, green: 0.85, blue: 0.35, alpha: 0.65).cgColor
                    : NSColor(srgbRed: 0.85, green: 0.65, blue: 0.12, alpha: 0.60).cgColor
            } else if score.isUtility || score.score < 4.0 {
                aestheticLabel.stringValue = "⚠️ \(score.formattedScore)"
                aestheticLabel.textColor = isDark ? NSColor.systemYellow : NSColor.systemOrange
                aestheticPill.layer?.backgroundColor = isDark
                    ? NSColor(white: 0.20, alpha: 0.40).cgColor
                    : NSColor(white: 0.85, alpha: 0.50).cgColor
                aestheticPill.layer?.borderColor = isDark
                    ? NSColor.systemOrange.withAlphaComponent(0.4).cgColor
                    : NSColor.systemOrange.withAlphaComponent(0.5).cgColor
            } else {
                aestheticLabel.stringValue = "✨ \(score.formattedScore)"
                aestheticLabel.textColor = theme.secondaryTextColor
                aestheticPill.layer?.backgroundColor = theme.pillBackgroundColor
                aestheticPill.layer?.borderColor = theme.pillBorderColor
            }
            aestheticPill.isHidden = false
        } else {
            aestheticPill.isHidden = true
        }
    }
}
