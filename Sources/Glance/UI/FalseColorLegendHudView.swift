import AppKit

/// Floating frosted-glass ARRI False Color IRE exposure scale legend HUD.
/// Appears alongside the viewport when False Color mode is toggled (`⇧O`).
@MainActor
public final class FalseColorLegendHudView: NSView {
    private let visualEffectView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "ARRI FALSE COLOR")
    private let stackView = NSStackView()

    private struct LegendItem {
        let ire: String
        let label: String
        let color: NSColor
    }

    private let items: [LegendItem] = [
        LegendItem(ire: "100", label: "CLIP", color: NSColor(srgbRed: 1.0, green: 0.0, blue: 0.17, alpha: 1.0)),
        LegendItem(ire: " 98", label: "ROLL", color: NSColor(srgbRed: 1.0, green: 0.90, blue: 0.0, alpha: 1.0)),
        LegendItem(ire: " 80", label: "HIGH", color: NSColor(srgbRed: 1.0, green: 0.48, blue: 0.0, alpha: 1.0)),
        LegendItem(ire: " 54", label: "SKIN", color: NSColor(srgbRed: 1.0, green: 0.40, blue: 0.70, alpha: 1.0)),
        LegendItem(ire: " 40", label: "18% GRAY", color: NSColor(srgbRed: 0.0, green: 0.90, blue: 0.30, alpha: 1.0)),
        LegendItem(ire: "  3", label: "SHADOW", color: NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)),
        LegendItem(ire: "  0", label: "CRUSH", color: NSColor(srgbRed: 0.55, green: 0.12, blue: 0.64, alpha: 1.0))
    ]

    public override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 140, height: 230))
        setupUI()
        setupThemeObserver()
        applyTheme()
    }

    public required init?(coder: NSCoder) {
        nil
    }

    private func setupUI() {
        wantsLayer = true
        isHidden = true
        alphaValue = 0.0

        // Floating drop shadow
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow

        // Frosted glass background
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 12
        visualEffectView.layer?.cornerCurve = .continuous
        visualEffectView.layer?.borderWidth = 0.75
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffectView)

        NSLayoutConstraint.activate([
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // Title Header
        titleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(titleLabel)

        // Vertical Rows Stack
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6
        stackView.distribution = .fillEqually
        stackView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(stackView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -8),

            stackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -12),
            stackView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -10)
        ])

        for item in items {
            let row = makeRowView(item: item)
            stackView.addArrangedSubview(row)
        }
    }

    private func makeRowView(item: LegendItem) -> NSView {
        let rowView = NSView()
        rowView.translatesAutoresizingMaskIntoConstraints = false

        // Color Swatch Chip
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = item.color.cgColor
        chip.layer?.cornerRadius = 3.0
        chip.layer?.cornerCurve = .continuous
        chip.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
        chip.layer?.borderWidth = 0.5
        chip.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(chip)

        // IRE Numerical Value Label
        let ireLabel = NSTextField(labelWithString: item.ire)
        ireLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        ireLabel.textColor = ThemeManager.shared.primaryTextColor
        ireLabel.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(ireLabel)

        // Descriptive Zone Label
        let nameLabel = NSTextField(labelWithString: item.label)
        nameLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        nameLabel.textColor = ThemeManager.shared.secondaryTextColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(nameLabel)

        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
            chip.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 10),
            chip.heightAnchor.constraint(equalToConstant: 10),

            ireLabel.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 7),
            ireLabel.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            ireLabel.widthAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: ireLabel.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: rowView.trailingAnchor)
        ])

        return rowView
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
        visualEffectView.layer?.borderColor = theme.glassBorderColor
        titleLabel.textColor = theme.secondaryTextColor

        let shadow = NSShadow()
        shadow.shadowColor = theme.shadowColor
        shadow.shadowBlurRadius = theme.isDark ? 16 : 12
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow
    }

    public func showLegend() {
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1.0
        }
    }

    public func hideLegend() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.alphaValue == 0.0 {
                    self?.isHidden = true
                }
            }
        }
    }
}
