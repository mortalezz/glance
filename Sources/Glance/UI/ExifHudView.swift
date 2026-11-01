import AppKit

/// Modern macOS frosted-glass HUD overlay displaying detailed EXIF camera & exposure metadata.
/// Expands smoothly on hover to reveal comprehensive shooting and technical specifications.
@MainActor
public final class ExifHudView: NSView {
    public var onHoverExpansionChanged: ((Bool) -> Void)?
    public var onCopiedExif: (() -> Void)?

    public private(set) var isExpanded: Bool = false

    private let visualEffectView = NSVisualEffectView()
    private let scrimView = NSView()

    // Header Row
    private let titleLabel = NSTextField(labelWithString: "EXIF INFO")
    private let expandBadge = ThemedPillView(text: "▾ Details", hasDot: false)
    private let timeBadgeLabel = NSTextField(labelWithString: "")

    // Recessed Exposure Scope Well (4 Columns: SHUTTER, APERTURE, ISO, FOCAL)
    private let exposureWell = NSView()
    private let shutterValueLabel = NSTextField(labelWithString: "—")
    private let apertureValueLabel = NSTextField(labelWithString: "—")
    private let isoValueLabel = NSTextField(labelWithString: "—")
    private let focalValueLabel = NSTextField(labelWithString: "—")
    private var exposureTitles: [NSTextField] = []

    // Camera & Lens Details
    private let cameraLabel = NSTextField(labelWithString: "—")
    private let lensLabel = NSTextField(labelWithString: "—")
    private let compactDivider = NSView()

    // File & Capture Details (Compact summary)
    private let dateLabel = NSTextField(labelWithString: "—")
    private let techLabel = NSTextField(labelWithString: "—")

    // MARK: - Expanded Photographer Dossier (Revealed on Hover)
    private let expandedContainer = NSStackView()
    private let expandedDivider = NSView()
    private let expandedTitleLabel = NSTextField(labelWithString: "")

    // Left Column: Exposure & Optics
    private let expProgramValueLabel = NSTextField(labelWithString: "—")
    private let meteringValueLabel = NSTextField(labelWithString: "—")
    private let biasValueLabel = NSTextField(labelWithString: "—")
    private let wbValueLabel = NSTextField(labelWithString: "—")
    private let focalOpticsValueLabel = NSTextField(labelWithString: "—")

    // Right Column: Color, Profile & Hardware
    private let profileValueLabel = NSTextField(labelWithString: "—")
    private let colorSpaceValueLabel = NSTextField(labelWithString: "—")
    private let flashValueLabel = NSTextField(labelWithString: "—")
    private let resolutionValueLabel = NSTextField(labelWithString: "—")
    private let hardwareValueLabel = NSTextField(labelWithString: "—")

    private let copyHintLabel = NSTextField(labelWithString: "💡 Click card to copy EXIF summary to clipboard")
    private var detailTitles: [NSTextField] = []

    private var currentExifSummary: String = ""
    private var trackingArea: NSTrackingArea?

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

    // MARK: - Interactive Hit Testing & Hover Tracking

    public override func updateTrackingAreas() {
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

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard alphaValue > 0.05, bounds.contains(point) else { return nil }
        return self
    }

    public override func mouseEntered(with event: NSEvent) {
        guard alphaValue > 0.05 else { return }
        setExpanded(true, animated: true)
    }

    public override func mouseExited(with event: NSEvent) {
        setExpanded(false, animated: true)
    }

    public override func mouseDown(with event: NSEvent) {
        guard !currentExifSummary.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentExifSummary, forType: .string)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        onCopiedExif?()
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

        // 1. Header Row (Title, Expand Pill Badge, Time Badge)
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        updateTitleLabel()
        header.addArrangedSubview(titleLabel)

        expandBadge.label.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        header.addArrangedSubview(expandBadge)

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
        compactDivider.wantsLayer = true
        compactDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(compactDivider)
        NSLayoutConstraint.activate([
            compactDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            compactDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            compactDivider.heightAnchor.constraint(equalToConstant: 0.5)
        ])

        // 4. Capture Date & Technical Details (Compact summary)
        dateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        root.addArrangedSubview(dateLabel)

        techLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        root.addArrangedSubview(techLabel)

        // 5. Expanded Photographer Dossier (Hidden by default, unfolds on hover)
        expandedContainer.orientation = .vertical
        expandedContainer.alignment = .leading
        expandedContainer.spacing = 8
        expandedContainer.translatesAutoresizingMaskIntoConstraints = false
        expandedContainer.isHidden = true
        expandedContainer.alphaValue = 0.0

        expandedDivider.wantsLayer = true
        expandedDivider.translatesAutoresizingMaskIntoConstraints = false
        expandedContainer.addArrangedSubview(expandedDivider)
        NSLayoutConstraint.activate([
            expandedDivider.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            expandedDivider.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor),
            expandedDivider.heightAnchor.constraint(equalToConstant: 0.5)
        ])

        updateExpandedTitleLabel()
        expandedContainer.addArrangedSubview(expandedTitleLabel)

        // 2-Column Photographer Detail Grid
        let columnsStack = NSStackView()
        columnsStack.orientation = .horizontal
        columnsStack.alignment = .top
        columnsStack.distribution = .fillEqually
        columnsStack.spacing = 16
        columnsStack.translatesAutoresizingMaskIntoConstraints = false

        // Left Column: Exposure & Optics
        let leftCol = NSStackView()
        leftCol.orientation = .vertical
        leftCol.alignment = .leading
        leftCol.spacing = 6
        leftCol.translatesAutoresizingMaskIntoConstraints = false

        leftCol.addArrangedSubview(makeDetailRow(label: "EXPOSURE PROGRAM", valueLabel: expProgramValueLabel))
        leftCol.addArrangedSubview(makeDetailRow(label: "METERING MODE", valueLabel: meteringValueLabel))
        leftCol.addArrangedSubview(makeDetailRow(label: "EXPOSURE BIAS", valueLabel: biasValueLabel))
        leftCol.addArrangedSubview(makeDetailRow(label: "WHITE BALANCE", valueLabel: wbValueLabel))
        leftCol.addArrangedSubview(makeDetailRow(label: "FOCAL & OPTICS", valueLabel: focalOpticsValueLabel))

        // Right Column: Color, Processing & Hardware
        let rightCol = NSStackView()
        rightCol.orientation = .vertical
        rightCol.alignment = .leading
        rightCol.spacing = 6
        rightCol.translatesAutoresizingMaskIntoConstraints = false

        rightCol.addArrangedSubview(makeDetailRow(label: "COLOR PROFILE", valueLabel: profileValueLabel))
        rightCol.addArrangedSubview(makeDetailRow(label: "COLOR SPACE", valueLabel: colorSpaceValueLabel))
        rightCol.addArrangedSubview(makeDetailRow(label: "FLASH MODE", valueLabel: flashValueLabel))
        rightCol.addArrangedSubview(makeDetailRow(label: "SENSOR & RESOLUTION", valueLabel: resolutionValueLabel))
        rightCol.addArrangedSubview(makeDetailRow(label: "HARDWARE / SHUTTER", valueLabel: hardwareValueLabel))

        columnsStack.addArrangedSubview(leftCol)
        columnsStack.addArrangedSubview(rightCol)
        expandedContainer.addArrangedSubview(columnsStack)
        NSLayoutConstraint.activate([
            columnsStack.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            columnsStack.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor)
        ])

        // Copy Hint Footer
        copyHintLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        copyHintLabel.alignment = .center
        copyHintLabel.translatesAutoresizingMaskIntoConstraints = false
        expandedContainer.addArrangedSubview(copyHintLabel)
        NSLayoutConstraint.activate([
            copyHintLabel.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            copyHintLabel.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor)
        ])

        root.addArrangedSubview(expandedContainer)
        NSLayoutConstraint.activate([
            expandedContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            expandedContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])

        // Insets from HUD window edges
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

    private func updateExpandedTitleLabel() {
        let attr = NSMutableAttributedString(
            string: "SHOOTING & TECHNICAL SPECIFICATIONS",
            attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: ThemeManager.shared.tertiaryTextColor,
                .kern: 0.8
            ]
        )
        expandedTitleLabel.attributedStringValue = attr
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

    private func makeDetailRow(label: String, valueLabel: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 1
        row.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(labelWithString: label)
        detailTitles.append(lbl)
        updateDetailTitle(lbl, title: label)
        row.addArrangedSubview(lbl)

        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(valueLabel)

        return row
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

    private func updateDetailTitle(_ label: NSTextField, title: String) {
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 7.5, weight: .bold),
                .foregroundColor: ThemeManager.shared.tertiaryTextColor,
                .kern: 0.6
            ]
        )
        label.attributedStringValue = attr
    }

    // MARK: - Expanded Hover Animation

    public func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded

        expandBadge.label.stringValue = expanded ? "▴ Expanded" : "▾ Details"
        expandBadge.hasIndicatorDot = expanded
        expandBadge.indicatorDot.backgroundColor = NSColor.systemCyan.cgColor

        onHoverExpansionChanged?(expanded)

        let duration = animated ? 0.22 : 0.0
        if expanded {
            expandedContainer.isHidden = false
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.expandedContainer.animator().alphaValue = expanded ? 1.0 : 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if !self.isExpanded {
                    self.expandedContainer.isHidden = true
                }
            }
        })
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

        updateTitleLabel()
        updateExpandedTitleLabel()
        expandBadge.applyTheme()
        timeBadgeLabel.textColor = theme.secondaryTextColor

        exposureWell.layer?.backgroundColor = theme.wellBackgroundColor
        exposureWell.layer?.borderColor = theme.pillBorderColor

        for tf in exposureTitles {
            updateExposureTitle(tf, title: tf.stringValue)
        }
        for dt in detailTitles {
            updateDetailTitle(dt, title: dt.stringValue)
        }

        shutterValueLabel.textColor = theme.primaryTextColor
        apertureValueLabel.textColor = theme.primaryTextColor
        isoValueLabel.textColor = theme.primaryTextColor
        focalValueLabel.textColor = theme.primaryTextColor

        cameraLabel.textColor = theme.primaryTextColor
        lensLabel.textColor = theme.secondaryTextColor

        compactDivider.layer?.backgroundColor = theme.dividerColor
        expandedDivider.layer?.backgroundColor = theme.dividerColor

        dateLabel.textColor = theme.secondaryTextColor
        techLabel.textColor = theme.secondaryTextColor
        copyHintLabel.textColor = theme.tertiaryTextColor

        expProgramValueLabel.textColor = theme.primaryTextColor
        meteringValueLabel.textColor = theme.primaryTextColor
        biasValueLabel.textColor = theme.primaryTextColor
        wbValueLabel.textColor = theme.primaryTextColor
        focalOpticsValueLabel.textColor = theme.primaryTextColor

        profileValueLabel.textColor = theme.primaryTextColor
        colorSpaceValueLabel.textColor = theme.primaryTextColor
        flashValueLabel.textColor = theme.primaryTextColor
        resolutionValueLabel.textColor = theme.primaryTextColor
        hardwareValueLabel.textColor = theme.primaryTextColor
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

            expProgramValueLabel.stringValue = "—"
            meteringValueLabel.stringValue = "—"
            biasValueLabel.stringValue = "—"
            wbValueLabel.stringValue = "—"
            focalOpticsValueLabel.stringValue = "—"
            profileValueLabel.stringValue = "—"
            colorSpaceValueLabel.stringValue = "—"
            flashValueLabel.stringValue = "—"
            resolutionValueLabel.stringValue = dimensions ?? "—"
            hardwareValueLabel.stringValue = "—"
            currentExifSummary = ""
            return
        }

        shutterValueLabel.stringValue = exif.formattedShutter ?? "—"
        apertureValueLabel.stringValue = exif.formattedAperture ?? "—"
        isoValueLabel.stringValue = exif.iso.map { "\($0)" } ?? "—"
        focalValueLabel.stringValue = exif.formattedFocal ?? "—"

        // Camera
        let camStr: String
        if let model = exif.cameraModel {
            if let make = exif.cameraMake, !model.lowercased().contains(make.lowercased()) {
                camStr = "\(make) \(model)"
            } else {
                camStr = model
            }
        } else if let make = exif.cameraMake {
            camStr = make
        } else {
            camStr = "Unknown Camera"
        }
        cameraLabel.stringValue = camStr

        // Lens
        let lensStr = exif.lensModel ?? "Standard Lens"
        lensLabel.stringValue = lensStr

        // Date
        dateLabel.stringValue = exif.formattedDate ?? "Unknown Date"

        // Technical details line (Compact)
        var techParts: [String] = []
        if let bias = exif.formattedBias {
            techParts.append(bias)
        }
        if let profile = exif.pictureControl {
            techParts.append("Profile: \(profile)")
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

        // Expanded Dossier Values
        expProgramValueLabel.stringValue = exif.formattedExposureProgram ?? "Manual (M)"
        meteringValueLabel.stringValue = exif.formattedMeteringMode ?? "Multi-Segment (Matrix)"
        biasValueLabel.stringValue = exif.formattedBias ?? "0.0 EV"
        wbValueLabel.stringValue = exif.formattedWhiteBalance ?? "Auto (AWB)"
        focalOpticsValueLabel.stringValue = exif.formattedFocalWithEquivalent ?? (exif.formattedFocal ?? "—")

        profileValueLabel.stringValue = exif.pictureControl ?? "Standard / As Shot"
        colorSpaceValueLabel.stringValue = exif.formattedColorSpace ?? "sRGB"
        flashValueLabel.stringValue = exif.formattedFlash ?? (exif.flashFired == true ? "Fired" : "Off (Did not fire)")

        // Megapixels & Resolution
        if let dim = dimensions {
            let components = dim.components(separatedBy: " × ")
            if components.count == 2, let w = Double(components[0]), let h = Double(components[1]) {
                let mp = (w * h) / 1_000_000.0
                resolutionValueLabel.stringValue = String(format: "%.1f MP (%@)", mp, dim)
            } else {
                resolutionValueLabel.stringValue = dim
            }
        } else {
            resolutionValueLabel.stringValue = "—"
        }

        // Hardware details: Shutter Count / Body Serial
        var hwParts: [String] = []
        if let sc = exif.formattedShutterCount {
            hwParts.append(sc)
        }
        if let sn = exif.bodySerialNumber, !sn.isEmpty {
            hwParts.append("S/N: \(sn)")
        }
        if hwParts.isEmpty, let sw = exif.software, !sw.isEmpty {
            hwParts.append(sw)
        }
        hardwareValueLabel.stringValue = hwParts.isEmpty ? "Standard Camera Body" : hwParts.joined(separator: " · ")

        // Prepare clipboard summary
        var summaryItems: [String] = []
        summaryItems.append(camStr)
        if lensStr != "Standard Lens" { summaryItems.append(lensStr) }
        summaryItems.append(exif.exposureSummary)
        if let d = dimensions { summaryItems.append(d) }
        if let s = fileSize { summaryItems.append(s) }
        currentExifSummary = summaryItems.joined(separator: " · ")
    }

    public func setVisible(_ visible: Bool, animated: Bool = true) {
        let targetAlpha: CGFloat = visible ? 1.0 : 0.0
        guard alphaValue != targetAlpha else { return }

        if !visible {
            setExpanded(false, animated: false)
        }

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
