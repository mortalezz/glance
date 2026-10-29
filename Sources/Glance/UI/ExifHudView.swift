import AppKit

/// Modern macOS frosted-glass HUD overlay displaying detailed EXIF camera & exposure metadata.
@MainActor
public final class ExifHudView: NSView {
    private let visualEffectView = NSVisualEffectView()
    private let scrimView = NSView()

    // Header
    private let titleLabel = NSTextField(labelWithString: "EXIF INFO")
    private let timeBadgeLabel = NSTextField(labelWithString: "")

    // Recessed Exposure Scope Well
    private let exposureWell = NSView()
    private let shutterValueLabel = NSTextField(labelWithString: "—")
    private let apertureValueLabel = NSTextField(labelWithString: "—")
    private let isoValueLabel = NSTextField(labelWithString: "—")
    private let focalValueLabel = NSTextField(labelWithString: "—")
    private var exposureTitles: [NSTextField] = []

    // Camera & Lens Details
    private let cameraLabel = NSTextField(labelWithString: "—")
    private let lensLabel = NSTextField(labelWithString: "—")
    private let divider = NSView()

    // File & Capture Details
    private let dateLabel = NSTextField(labelWithString: "—")
    private let techLabel = NSTextField(labelWithString: "—")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
        setupContent()
        setupThemeObserver()
        applyTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGlass()
        setupContent()
        setupThemeObserver()
        applyTheme()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    private func setupGlass() {
        wantsLayer = true
        alphaValue = 0.0

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false

        if let layer = visualEffectView.layer {
            layer.cornerRadius = 14
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.borderWidth = 0.75
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
    }

    private func setupContent() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(root)

        // 1. Header Row
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        updateTitleLabel()
        header.addArrangedSubview(titleLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)

        timeBadgeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        header.addArrangedSubview(timeBadgeLabel)

        root.addArrangedSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])

        // 2. Recessed Exposure Well (4 Columns: SHUTTER, APERTURE, ISO, FOCAL)
        exposureWell.translatesAutoresizingMaskIntoConstraints = false
        exposureWell.wantsLayer = true
        if let layer = exposureWell.layer {
            layer.cornerRadius = 7
            layer.cornerCurve = .continuous
            layer.borderWidth = 0.5
            layer.masksToBounds = true
        }

        let exposureGrid = NSStackView()
        exposureGrid.orientation = .horizontal
        exposureGrid.alignment = .centerY
        exposureGrid.distribution = .fillEqually
        exposureGrid.spacing = 4
        exposureGrid.translatesAutoresizingMaskIntoConstraints = false

        exposureGrid.addArrangedSubview(makeExposureColumn(title: "SHUTTER", valueLabel: shutterValueLabel))
        exposureGrid.addArrangedSubview(makeExposureColumn(title: "APERTURE", valueLabel: apertureValueLabel))
        exposureGrid.addArrangedSubview(makeExposureColumn(title: "ISO", valueLabel: isoValueLabel))
        exposureGrid.addArrangedSubview(makeExposureColumn(title: "FOCAL", valueLabel: focalValueLabel))

        exposureWell.addSubview(exposureGrid)
        NSLayoutConstraint.activate([
            exposureGrid.topAnchor.constraint(equalTo: exposureWell.topAnchor, constant: 6),
            exposureGrid.bottomAnchor.constraint(equalTo: exposureWell.bottomAnchor, constant: -6),
            exposureGrid.leadingAnchor.constraint(equalTo: exposureWell.leadingAnchor, constant: 8),
            exposureGrid.trailingAnchor.constraint(equalTo: exposureWell.trailingAnchor, constant: -8)
        ])

        root.addArrangedSubview(exposureWell)
        NSLayoutConstraint.activate([
            exposureWell.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            exposureWell.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            exposureWell.heightAnchor.constraint(equalToConstant: 44)
        ])

        // 3. Camera & Lens Details
        cameraLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        cameraLabel.lineBreakMode = .byTruncatingTail
        cameraLabel.maximumNumberOfLines = 1
        root.addArrangedSubview(cameraLabel)

        lensLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        lensLabel.lineBreakMode = .byTruncatingTail
        lensLabel.maximumNumberOfLines = 1
        root.addArrangedSubview(lensLabel)

        // Subtle divider
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(divider)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 0.5)
        ])

        // 4. Capture Date & Technical Details
        dateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        root.addArrangedSubview(dateLabel)

        techLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        root.addArrangedSubview(techLabel)

        // Generous, balanced insets from HUD window edges (14pt left/right, 12pt top, 10pt bottom)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -10),
            root.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -14)
        ])
    }

    private func updateTitleLabel() {
        let attrTitle = NSMutableAttributedString(
            string: "EXIF INFO",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: ThemeManager.shared.primaryTextColor,
                .kern: 0.8
            ]
        )
        titleLabel.attributedStringValue = attrTitle
    }

    private func makeExposureColumn(title: String, valueLabel: NSTextField) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .centerX
        col.spacing = 2

        let tfTitle = NSTextField(labelWithString: title)
        exposureTitles.append(tfTitle)
        updateExposureTitle(tfTitle, title: title)
        col.addArrangedSubview(tfTitle)

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        valueLabel.alignment = .center
        col.addArrangedSubview(valueLabel)

        return col
    }

    private func updateExposureTitle(_ label: NSTextField, title: String) {
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 7.5, weight: .bold),
                .foregroundColor: ThemeManager.shared.tertiaryTextColor,
                .kern: 0.5
            ]
        )
        label.attributedStringValue = attr
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
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowBlurRadius = 18
        self.shadow = shadow

        updateTitleLabel()
        timeBadgeLabel.textColor = theme.secondaryTextColor

        exposureWell.layer?.backgroundColor = theme.wellBackgroundColor
        exposureWell.layer?.borderColor = theme.pillBorderColor

        for tf in exposureTitles {
            updateExposureTitle(tf, title: tf.stringValue)
        }

        shutterValueLabel.textColor = theme.primaryTextColor
        apertureValueLabel.textColor = theme.primaryTextColor
        isoValueLabel.textColor = theme.primaryTextColor
        focalValueLabel.textColor = theme.primaryTextColor

        cameraLabel.textColor = theme.primaryTextColor
        lensLabel.textColor = theme.secondaryTextColor

        divider.layer?.backgroundColor = theme.dividerColor

        dateLabel.textColor = theme.secondaryTextColor
        techLabel.textColor = theme.secondaryTextColor
    }

    public func update(with exif: ExifMetadata?, dimensions: String?, fileSize: String?) {
        guard let exif = exif else {
            shutterValueLabel.stringValue = "—"
            apertureValueLabel.stringValue = "—"
            isoValueLabel.stringValue = "—"
            focalValueLabel.stringValue = "—"
            cameraLabel.stringValue = "No EXIF camera data"
            lensLabel.stringValue = "—"
            dateLabel.stringValue = "—"

            var techParts: [String] = []
            if let d = dimensions { techParts.append(d) }
            if let s = fileSize { techParts.append(s) }
            techLabel.stringValue = techParts.isEmpty ? "—" : techParts.joined(separator: "  •  ")
            timeBadgeLabel.stringValue = ""
            return
        }

        shutterValueLabel.stringValue = exif.formattedShutter ?? "—"
        apertureValueLabel.stringValue = exif.formattedAperture ?? "—"
        isoValueLabel.stringValue = exif.iso.map { "\($0)" } ?? "—"
        focalValueLabel.stringValue = exif.formattedFocal ?? "—"

        // Camera
        if let model = exif.cameraModel {
            if let make = exif.cameraMake, !model.lowercased().contains(make.lowercased()) {
                cameraLabel.stringValue = "\(make) \(model)"
            } else {
                cameraLabel.stringValue = model
            }
        } else if let make = exif.cameraMake {
            cameraLabel.stringValue = make
        } else {
            cameraLabel.stringValue = "Unknown Camera"
        }

        // Lens
        lensLabel.stringValue = exif.lensModel ?? "Standard Lens"

        // Date
        dateLabel.stringValue = exif.formattedDate ?? "Unknown Date"

        // Technical details line
        var techParts: [String] = []
        if let bias = exif.formattedBias {
            techParts.append(bias)
        }
        if let flash = exif.flashFired {
            techParts.append(flash ? "Flash: Fired" : "Flash: Off")
        }
        if let d = dimensions {
            techParts.append(d)
        }
        if let s = fileSize {
            techParts.append(s)
        }
        techLabel.stringValue = techParts.joined(separator: "  •  ")

        // Top right time badge
        if let dateStr = exif.formattedDate, let timeOnly = dateStr.components(separatedBy: " at ").last {
            timeBadgeLabel.stringValue = timeOnly
        } else {
            timeBadgeLabel.stringValue = ""
        }
    }

    public func setVisible(_ visible: Bool, animated: Bool = true) {
        let targetAlpha: CGFloat = visible ? 1.0 : 0.0
        guard alphaValue != targetAlpha else { return }

        applyTheme()

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                self.animator().alphaValue = targetAlpha
            }
        } else {
            alphaValue = targetAlpha
        }
    }
}
