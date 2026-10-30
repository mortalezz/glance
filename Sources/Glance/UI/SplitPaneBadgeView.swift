import AppKit

/// Model info passed to each split compare badge pane.
public struct SplitPaneInfo: Sendable {
    public let slot: Int // 1 or 2
    public let filename: String
    public let pick: PickStatus
    public let rating: Int
    public let color: ColorLabel
    public let isChampion: Bool

    public init(
        slot: Int,
        filename: String,
        pick: PickStatus,
        rating: Int = 0,
        color: ColorLabel = .none,
        isChampion: Bool = false
    ) {
        self.slot = slot
        self.filename = filename
        self.pick = pick
        self.rating = rating
        self.color = color
        self.isChampion = isChampion
    }
}

/// Frosted glass floating pill badge labeling panes in 2-UP Split Compare mode (e.g. "[ 1 ] DSC_3088.NEF  ✓ PICK").
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

    // 3. Status Pill: ✓ PICK / ✕ REJECT / PRESS 1
    private let statusPill = NSView()
    private let statusLabel = NSTextField(labelWithString: "")

    public let slot: Int

    public init(slot: Int) {
        self.slot = slot
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) {
        self.slot = 1
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

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

        // 3. Status Pill setup
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

    public func update(with info: SplitPaneInfo?) {
        guard let info = info else {
            isHidden = true
            return
        }

        isHidden = false
        keycapLabel.stringValue = "\(info.slot)"
        filenameLabel.stringValue = info.filename

        let isDark = ThemeManager.shared.isDark
        let starSuffix = info.rating > 0 ? " ★\(info.rating)" : ""

        switch info.pick {
        case .pick:
            statusLabel.stringValue = (info.isChampion ? "👑 CHAMPION" : "✓ PICK") + starSuffix
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
            statusLabel.textColor = isDark ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
            statusPill.layer?.backgroundColor = isDark
                ? NSColor(white: 0.20, alpha: 0.40).cgColor
                : NSColor(white: 0.85, alpha: 0.50).cgColor
            statusPill.layer?.borderColor = isDark
                ? NSColor(white: 1.0, alpha: 0.10).cgColor
                : NSColor(white: 0.0, alpha: 0.10).cgColor
            statusPill.isHidden = false
        }

        updateTheme()
    }

    public func updateTheme() {
        let isDark = ThemeManager.shared.isDark

        visualEffectView.material = isDark ? .hudWindow : .headerView
        visualEffectView.layer?.borderColor = isDark
            ? NSColor(white: 1.0, alpha: 0.15).cgColor
            : NSColor(white: 0.0, alpha: 0.12).cgColor

        scrimView.layer?.backgroundColor = isDark
            ? NSColor(white: 0.05, alpha: 0.25).cgColor
            : NSColor(white: 1.0, alpha: 0.35).cgColor

        // Keycap appearance
        if slot == 1 {
            // Indigo / Blue for Slot 1
            keycapPill.layer?.backgroundColor = isDark
                ? NSColor(srgbRed: 0.25, green: 0.38, blue: 0.85, alpha: 0.85).cgColor
                : NSColor(srgbRed: 0.20, green: 0.45, blue: 0.90, alpha: 0.85).cgColor
            keycapPill.layer?.borderColor = NSColor(srgbRed: 0.45, green: 0.65, blue: 1.0, alpha: 0.50).cgColor
            keycapLabel.textColor = .white
        } else {
            // Amber / Orange for Slot 2
            keycapPill.layer?.backgroundColor = isDark
                ? NSColor(srgbRed: 0.85, green: 0.45, blue: 0.15, alpha: 0.85).cgColor
                : NSColor(srgbRed: 0.90, green: 0.50, blue: 0.15, alpha: 0.85).cgColor
            keycapPill.layer?.borderColor = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.35, alpha: 0.50).cgColor
            keycapLabel.textColor = .white
        }

        filenameLabel.textColor = isDark ? .white : .black
    }
}
