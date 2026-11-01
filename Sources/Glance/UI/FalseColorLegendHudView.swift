import AppKit

/// Floating frosted-glass ARRI False Color IRE exposure scale legend HUD.
/// Inherits from `ThemedGlassCardView` to guarantee identical HIG appearance,
/// scrim bleed-through prevention, corner radii, and dynamic theme reactivity.
@MainActor
public final class FalseColorLegendHudView: ThemedGlassCardView {
    private let titleLabel = NSTextField(labelWithString: "ARRI FALSE COLOR")
    private let divider = NSView()
    private let stackView = NSStackView()

    private struct LegendEntry {
        let ire: String
        let label: String
        let color: NSColor
    }

    private let entries: [LegendEntry] = [
        LegendEntry(ire: "100", label: "CLIP", color: NSColor(srgbRed: 1.0, green: 0.0, blue: 0.17, alpha: 1.0)),
        LegendEntry(ire: " 98", label: "ROLL", color: NSColor(srgbRed: 1.0, green: 0.90, blue: 0.0, alpha: 1.0)),
        LegendEntry(ire: " 80", label: "HIGH", color: NSColor(srgbRed: 1.0, green: 0.48, blue: 0.0, alpha: 1.0)),
        LegendEntry(ire: " 54", label: "SKIN", color: NSColor(srgbRed: 1.0, green: 0.40, blue: 0.70, alpha: 1.0)),
        LegendEntry(ire: " 40", label: "18% GRAY", color: NSColor(srgbRed: 0.0, green: 0.90, blue: 0.30, alpha: 1.0)),
        LegendEntry(ire: "  3", label: "SHADOW", color: NSColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)),
        LegendEntry(ire: "  0", label: "CRUSH", color: NSColor(srgbRed: 0.55, green: 0.12, blue: 0.64, alpha: 1.0))
    ]

    private var rowViews: [(chip: NSView, ireLabel: NSTextField, zoneLabel: NSTextField)] = []

    public init() {
        super.init(cornerRadius: 14.0)
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

        // 1. Header Title
        titleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        // 2. Subtle Divider
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(divider)

        // 3. Vertical Rows Stack
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 7
        stackView.distribution = .fillEqually
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),

            divider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            divider.heightAnchor.constraint(equalToConstant: 0.5),

            stackView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11)
        ])

        for entry in entries {
            let row = makeRowView(entry: entry)
            stackView.addArrangedSubview(row.container)
            rowViews.append((chip: row.chip, ireLabel: row.ire, zoneLabel: row.zone))
        }
    }

    private func makeRowView(entry: LegendEntry) -> (container: NSView, chip: NSView, ire: NSTextField, zone: NSTextField) {
        let rowView = NSView()
        rowView.translatesAutoresizingMaskIntoConstraints = false

        // Color Chip
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = entry.color.cgColor
        chip.layer?.cornerRadius = 3.0
        chip.layer?.cornerCurve = .continuous
        chip.layer?.borderWidth = 0.5
        chip.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(chip)

        // IRE Numerical Value Label
        let ireLabel = NSTextField(labelWithString: entry.ire)
        ireLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        ireLabel.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(ireLabel)

        // Descriptive Zone Label
        let zoneLabel = NSTextField(labelWithString: entry.label)
        zoneLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        zoneLabel.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(zoneLabel)

        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
            chip.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 10),
            chip.heightAnchor.constraint(equalToConstant: 10),

            ireLabel.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 7),
            ireLabel.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            ireLabel.widthAnchor.constraint(equalToConstant: 24),

            zoneLabel.leadingAnchor.constraint(equalTo: ireLabel.trailingAnchor, constant: 4),
            zoneLabel.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            zoneLabel.trailingAnchor.constraint(equalTo: rowView.trailingAnchor)
        ])

        return (container: rowView, chip: chip, ire: ireLabel, zone: zoneLabel)
    }

    public override func updateCustomTheme(theme: ThemeManager) {
        // 1. Header Typography with kern tracking
        let attrTitle = NSMutableAttributedString(
            string: "ARRI FALSE COLOR",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: theme.primaryTextColor,
                .kern: 0.8
            ]
        )
        titleLabel.attributedStringValue = attrTitle

        // 2. Divider
        divider.layer?.backgroundColor = theme.dividerColor

        // 3. High-Contrast Typography & Dynamic Shadows
        let shadow = theme.standardTextShadow
        titleLabel.shadow = shadow

        // 4. Update all rows dynamically with contrast outlines
        let chipBorder = theme.isDark
            ? NSColor.white.withAlphaComponent(0.35).cgColor
            : NSColor.black.withAlphaComponent(0.25).cgColor

        for row in rowViews {
            row.chip.layer?.borderColor = chipBorder
            row.chip.layer?.borderWidth = 0.75
            row.ireLabel.textColor = theme.primaryTextColor
            row.ireLabel.shadow = shadow
            row.zoneLabel.textColor = theme.secondaryTextColor
            row.zoneLabel.shadow = shadow
        }
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
