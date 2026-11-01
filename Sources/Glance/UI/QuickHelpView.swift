import AppKit

/// Apple Pro frosted-glass shortcuts cheatsheet.
/// Features true table-grid alignment using native `NSGridView`, ensuring
/// every single row across all columns shares the exact same baseline and height.
/// Adheres strictly to Apple Human Interface Guidelines for pro dark & light HUDs.
@MainActor
public final class QuickHelpView: NSView {
    public private(set) var isExpanded: Bool = false
    public var onWillPresent: (() -> Void)?
    public var onWillDismiss: (() -> Void)?

    private let visualEffectView = NSVisualEffectView()
    private let scrimView = NSView()
    private var dismissTimer: Timer?

    private let rootStack = NSStackView()
    private let compactContainer = NSView()
    private let expandedContainer = NSView()
    private let cluePill = NSView()
    private let clueLabel = NSTextField(labelWithString: "")

    // Tracked subviews for dynamic theme updates
    private var keycaps: [NSView] = []
    private var keyLabels: [NSTextField] = []
    private var primaryLabels: [NSTextField] = []
    private var secondaryLabels: [NSTextField] = []
    private var headerLabels: [NSTextField] = []
    private var subHeaderLabels: [NSTextField] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
        setupContent()
        setupThemeObserver()
        applyTheme()
    }

    public required init?(coder: NSCoder) {
        nil
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
            layer.cornerRadius = 18
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.borderWidth = 0.5
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
        rootStack.orientation = .vertical
        rootStack.alignment = .centerX
        rootStack.spacing = 18
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(rootStack)

        // Strict Auto Layout margins ensure content can NEVER touch the rounded glass borders
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: visualEffectView.topAnchor, constant: 28),
            rootStack.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor, constant: -24),
            rootStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor, constant: 36),
            rootStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor, constant: -36)
        ])

        setupCompactLayout()
        setupExpandedLayout()
        setupCluePill()

        compactContainer.isHidden = false
        expandedContainer.isHidden = true
        updateClueLabel()
    }

    // MARK: - Compact Mode Layout (Table Grid Alignment)

    private func setupCompactLayout() {
        compactContainer.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = makeSectionHeader(title: "KEYBOARD SHORTCUTS")
        stack.addArrangedSubview(header)

        // Balanced 2-column table grid (13 rows each, perfectly aligned horizontally)
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 32
        grid.rowSpacing = 8

        let compactPairs: [(col1: (key: String, desc: String), col2: (key: String, desc: String))] = [
            (("P / ⇧P", "Pick / Burst Knockout"), ("Z / ⇧Z", "100% Loupe / Eye Jump")),
            (("X / U", "Reject / Unflag"), ("M", "Magnifier Loupe (2× / 4×)")),
            (("1 – 5", "Rating (0 to clear)"), ("A", "Faces (Narrative dock)")),
            (("6 – 9", "Color labels"), ("S", "Multi-Up (1 / 2 / 4-UP)")),
            (("C", "Auto-advance (ON)"), ("H", "RGB Histogram")),
            (("\\ / ⇧\\", "Filter / Picks review"), ("O / ⇧O", "Blinkies / False Color")),
            (("Space / →", "Next / Prev photo"), ("F / ⇧F", "Fullscreen / Peaking")),
            (("[ / ]", "Scene leap"), ("I", "EXIF (Hover expand)")),
            (("B", "Best in burst (Hero)"), ("V / T", "Profile / Theme")),
            (("E / ⇧E", "Export / Batch Selects"), ("Return", "Slideshow (+ / - speed)")),
            (("R / L", "Lossless rotate 90°"), ("⌘↵ / ⌘O", "Open in Lightroom/PS")),
            (("⌫ / ⇧⌫", "Trash / Purge rejects"), ("⌘Z / ⇧⌘Z", "Multi-Step Undo / Redo")),
            (("?", "Cheatsheet toggle"), ("Esc / Q", "Dismiss / Quit Glance"))
        ]

        for pair in compactPairs {
            let rowCell1 = makeCompactRow(key: pair.col1.key, desc: pair.col1.desc)
            let rowCell2 = makeCompactRow(key: pair.col2.key, desc: pair.col2.desc)
            grid.addRow(with: [rowCell1, rowCell2])
        }

        grid.column(at: 0).width = 205
        grid.column(at: 1).width = 225

        stack.addArrangedSubview(grid)
        compactContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: compactContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: compactContainer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: compactContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: compactContainer.trailingAnchor)
        ])

        rootStack.addArrangedSubview(compactContainer)
    }

    private func makeCompactRow(key: String, desc: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let keycap = makeKeycap(text: key, fixedWidth: 54)
        row.addArrangedSubview(keycap)

        let descLabel = NSTextField(labelWithString: desc)
        descLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        descLabel.lineBreakMode = .byClipping
        primaryLabels.append(descLabel)
        row.addArrangedSubview(descLabel)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        return row
    }

    // MARK: - Expanded Mode Layout (3-Column Table Grid Alignment)

    private func setupExpandedLayout() {
        expandedContainer.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = makeSectionHeader(title: "DETAILED SHORTCUTS GUIDE")
        stack.addArrangedSubview(header)

        // Native 3-column table grid: guarantees identical row heights & baseline alignment across all columns
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 32
        grid.rowSpacing = 12

        // Section Sub-headers Row
        let h1 = makeSectionSubHeader(title: "CULLING & XMP SYNC")
        let h2 = makeSectionSubHeader(title: "INSPECTION & TONAL TOOLS")
        let h3 = makeSectionSubHeader(title: "WORKFLOW & OUTPUT")
        grid.addRow(with: [h1, h2, h3])

        // 8 Matched Table Rows across all 3 functional domains
        let rowsData: [(
            c1: (key: String, title: String, desc: String),
            c2: (key: String, title: String, desc: String),
            c3: (key: String, title: String, desc: String)
        )] = [
            (
                ("P / ⇧P", "Pick / Burst Knockout", "P: Flag keeper (xmp:Pick=1). ⇧P: Burst Knockout (pick best, auto-reject burst siblings)."),
                ("Z / ⇧Z", "100% Loupe & Eye Jump", "Z: Instant 1:1 Loupe peep at cursor. ⇧Z: Jump Loupe directly to detected eye or face."),
                ("Space / →", "Photo Navigation", "Space or → advances to next photo. ← goes back. Home / End jump to first or last photo.")
            ),
            (
                ("X / U", "Reject / Unflag", "X: Mark reject (xmp:Rating=-1). U: Clear flags back to neutral in Adobe XMP sidecar."),
                ("M", "Floating Optical Loupe", "2× / 4× circular reticle loupe. Press M or click to cycle 2× ➔ 4× ➔ Off. Use + / - to zoom."),
                ("[ / ] / B", "Scene Leap & Hero", "[ / ]: Leap across scenes / bursts. B: Leap directly to 👑 Best in Burst (Hero shot).")
            ),
            (
                ("1 – 5", "Star Ratings", "Sets 1 to 5 stars (xmp:Rating). Press 0 to clear stars. Syncs instantly to .xmp sidecar."),
                ("A", "Face Inspection Dock", "Narrative face crop strip with AI sharpness scores. ON by default; auto-hides if 0 faces."),
                ("E / ⇧E", "Export & Batch Selects", "E: Quick export active photo. ⇧E: Batch-export all ✓ Picks to ./Selects directory.")
            ),
            (
                ("6 – 9", "Color Labels", "Sets Adobe label: 6: Red, 7: Yellow, 8: Green, 9: Blue in sidecar XMP."),
                ("S", "Scene Multi-Up", "Cycles 1-UP ➔ 2-UP split ➔ 4-UP quad grid; bursts stay grouped on one sheet."),
                ("R / L", "Lossless 90° Rotation", "R: Rotate 90° CW. L: Rotate 90° CCW via lossless EXIF orientation rewrite.")
            ),
            (
                ("C", "Auto-Advance", "Speed culling: automatically advances after rating, flag, or color change (ON by default)."),
                ("H", "RGB Histogram", "Real-time 256-bin RGB and Rec. 709 Luminance tonal curve distribution overlay."),
                ("V / T", "Color Profile & Theme", "V: Cycle Camera Picture Controls / Film Sims. T: Switch between Frosted Dark & Light glass.")
            ),
            (
                ("\\ / ⇧\\", "Filters & Picks Review", "\\: Cycle populated filters (skips unassigned). ⇧\\: Instant toggle between Picks Only and All Files."),
                ("O / ⇧O", "Clipping & False Color", "O: Pulsing zebra blinkies. ⇧O: ARRI 7-band False Color exposure HUD with IRE scale."),
                ("Return", "Slideshow Presentation", "Timed hands-free presentation. Press + / - to step speed (1s to 30s). Any key stops it.")
            ),
            (
                ("⌫ / ⇧⌫", "Trash & Purge Rejects", "⌫ moves photo to macOS Trash. ⇧⌫ batch-purges all rejected photos from disk."),
                ("F / ⇧F", "Full Screen & Peaking", "F: Edge-to-edge borderless mode. ⇧F: EVF focus peaking highlights in-focus subject planes."),
                ("⌘↵ / ⌘O", "Open in External Editor", "Quick handoff to Lightroom, Photoshop, or macOS default RAW photo editor.")
            ),
            (
                ("⌘Z / ⇧⌘Z", "Multi-Step Undo / Redo", "Full undo stack for ratings, flags, rotations, burst knockouts, and purge operations."),
                ("I", "EXIF Technical HUD", "Camera, lens, exposure. Hover to reveal full shooting dossier (metering, WB, shutter count). Click to copy."),
                ("Esc / Q", "Dismiss & Quit Glance", "Esc dismisses open overlays or zooms. Esc or Q quits Glance to reveal Finder.")
            )
        ]

        for item in rowsData {
            let cell1 = makeVerboseRow(key: item.c1.key, title: item.c1.title, desc: item.c1.desc)
            let cell2 = makeVerboseRow(key: item.c2.key, title: item.c2.title, desc: item.c2.desc)
            let cell3 = makeVerboseRow(key: item.c3.key, title: item.c3.title, desc: item.c3.desc)
            grid.addRow(with: [cell1, cell2, cell3])
        }

        grid.column(at: 0).width = 285
        grid.column(at: 1).width = 285
        grid.column(at: 2).width = 285

        stack.addArrangedSubview(grid)
        expandedContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: expandedContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor)
        ])

        rootStack.addArrangedSubview(expandedContainer)
    }

    // MARK: - Apple HIG Typography & Keycap Factory

    private func makeSectionHeader(title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        headerLabels.append(label)
        updateHeaderLabel(label, title: title)
        return label
    }

    private func makeSectionSubHeader(title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        subHeaderLabels.append(label)
        updateSubHeaderLabel(label, title: title)
        return label
    }

    private func updateHeaderLabel(_ label: NSTextField, title: String) {
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: ThemeManager.shared.tertiaryTextColor,
                .kern: 0.6
            ]
        )
        label.attributedStringValue = attr
    }

    private func updateSubHeaderLabel(_ label: NSTextField, title: String) {
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: ThemeManager.shared.subHeaderColor,
                .kern: 0.5
            ]
        )
        label.attributedStringValue = attr
    }

    private func makeKeycap(text: String, fixedWidth: CGFloat? = nil) -> NSView {
        let keycap = NSView()
        keycap.wantsLayer = true
        keycap.layer?.borderWidth = 0.5
        keycap.layer?.cornerRadius = 5
        keycap.layer?.cornerCurve = .continuous
        keycap.translatesAutoresizingMaskIntoConstraints = false

        let fontSize: CGFloat = (fixedWidth != nil) ? 10.0 : 10.5
        let keyLabel = NSTextField(labelWithString: text)
        keyLabel.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        keyLabel.alignment = .center
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        keycap.addSubview(keyLabel)

        if let width = fixedWidth {
            NSLayoutConstraint.activate([
                keycap.heightAnchor.constraint(equalToConstant: 20),
                keycap.widthAnchor.constraint(greaterThanOrEqualToConstant: width),
                keycap.widthAnchor.constraint(greaterThanOrEqualTo: keyLabel.widthAnchor, constant: 10),
                keyLabel.centerXAnchor.constraint(equalTo: keycap.centerXAnchor),
                keyLabel.centerYAnchor.constraint(equalTo: keycap.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                keycap.heightAnchor.constraint(equalToConstant: 21),
                keycap.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
                keycap.widthAnchor.constraint(greaterThanOrEqualTo: keyLabel.widthAnchor, constant: 14),
                keyLabel.centerXAnchor.constraint(equalTo: keycap.centerXAnchor),
                keyLabel.centerYAnchor.constraint(equalTo: keycap.centerYAnchor)
            ])
            keycap.setContentHuggingPriority(.required, for: .horizontal)
            keycap.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        keycaps.append(keycap)
        keyLabels.append(keyLabel)
        return keycap
    }

    private func makeVerboseRow(key: String, title: String, desc: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false

        let keycap = makeKeycap(text: key)
        row.addArrangedSubview(keycap)

        let descCol = NSStackView()
        descCol.orientation = .vertical
        descCol.alignment = .leading
        descCol.spacing = 2.5
        descCol.translatesAutoresizingMaskIntoConstraints = false

        // Apple Primary Hierarchy: labelColor
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        primaryLabels.append(titleLabel)
        descCol.addArrangedSubview(titleLabel)

        // Apple Secondary Hierarchy: secondaryLabelColor
        let detailLabel = NSTextField(wrappingLabelWithString: desc)
        detailLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondaryLabels.append(detailLabel)
        descCol.addArrangedSubview(detailLabel)

        row.addArrangedSubview(descCol)
        return row
    }

    // MARK: - Interactive Visual Clue Pill

    private func setupCluePill() {
        cluePill.wantsLayer = true
        cluePill.layer?.borderWidth = 0.5
        cluePill.layer?.cornerRadius = 11
        cluePill.layer?.cornerCurve = .continuous
        cluePill.translatesAutoresizingMaskIntoConstraints = false

        clueLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        clueLabel.alignment = .center
        clueLabel.translatesAutoresizingMaskIntoConstraints = false

        cluePill.addSubview(clueLabel)
        NSLayoutConstraint.activate([
            clueLabel.topAnchor.constraint(equalTo: cluePill.topAnchor, constant: 4),
            clueLabel.bottomAnchor.constraint(equalTo: cluePill.bottomAnchor, constant: -4),
            clueLabel.leadingAnchor.constraint(equalTo: cluePill.leadingAnchor, constant: 14),
            clueLabel.trailingAnchor.constraint(equalTo: cluePill.trailingAnchor, constant: -14)
        ])

        rootStack.addArrangedSubview(cluePill)
    }

    private func updateClueLabel() {
        let theme = ThemeManager.shared
        if isExpanded {
            clueLabel.stringValue = "␣ Space to collapse ▴  •  ⎋ Esc to close"
        } else {
            clueLabel.stringValue = "␣ Space to expand details ▾  •  ⎋ Esc to close"
        }
        cluePill.layer?.backgroundColor = theme.pillBackgroundColor
        cluePill.layer?.borderColor = theme.pillBorderColor
        clueLabel.textColor = theme.secondaryTextColor
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
        scrimView.layer?.backgroundColor = theme.helpScrimColor.cgColor
        visualEffectView.layer?.borderColor = theme.glassBorderColor

        let shadow = NSShadow()
        shadow.shadowColor = theme.shadowColor
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.shadowBlurRadius = 24
        self.shadow = shadow

        for keycap in keycaps {
            keycap.layer?.backgroundColor = theme.pillBackgroundColor
            keycap.layer?.borderColor = theme.pillBorderColor
        }
        for label in keyLabels {
            label.textColor = theme.primaryTextColor
        }
        for label in primaryLabels {
            label.textColor = theme.primaryTextColor
        }
        for label in secondaryLabels {
            label.textColor = theme.secondaryTextColor
        }
        for label in headerLabels {
            updateHeaderLabel(label, title: label.stringValue)
        }
        for label in subHeaderLabels {
            updateSubHeaderLabel(label, title: label.stringValue)
        }
        updateClueLabel()
    }

    // MARK: - Interactive Expand / Collapse Toggle

    public func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        updateClueLabel()
        resetDismissTimer(timeout: 5.0)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.compactContainer.animator().isHidden = false
            self.expandedContainer.animator().isHidden = true
            self.layoutSubtreeIfNeeded()
        }
    }

    public func toggleExpansion() {
        isExpanded.toggle()
        updateClueLabel()

        if isExpanded {
            dismissTimer?.invalidate()
            dismissTimer = nil
        } else {
            resetDismissTimer(timeout: 5.0)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.compactContainer.animator().isHidden = isExpanded
            self.expandedContainer.animator().isHidden = !isExpanded
            self.layoutSubtreeIfNeeded()
        }
    }

    // MARK: - Presentation & Auto-Dismiss Timer

    public func toggle() {
        if alphaValue > 0.0 {
            dismiss()
        } else {
            present()
        }
    }

    public func present() {
        onWillPresent?()
        applyTheme()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            self.animator().alphaValue = 1.0
        }

        if !isExpanded {
            resetDismissTimer(timeout: 5.0)
        }
    }

    public func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            self.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.onWillDismiss?()
            }
        })
    }

    private func resetDismissTimer(timeout: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismiss()
            }
        }
    }
}
