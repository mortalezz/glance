import AppKit

/// Apple Pro frosted-glass shortcuts cheatsheet.
/// Features true table-grid alignment using native `NSGridView`, ensuring
/// every single row across all columns shares the exact same baseline and height.
/// Adheres strictly to Apple Human Interface Guidelines for pro dark HUDs.
@MainActor
public final class QuickHelpView: NSView {
    public private(set) var isExpanded: Bool = false

    private let visualEffectView = NSVisualEffectView()
    private let scrimView = NSView()
    private var dismissTimer: Timer?

    private let rootStack = NSStackView()
    private let compactContainer = NSView()
    private let expandedContainer = NSView()
    private let cluePill = NSView()
    private let clueLabel = NSTextField(labelWithString: "")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGlass()
        setupContent()
    }

    public required init?(coder: NSCoder) {
        nil
    }

    private func setupGlass() {
        wantsLayer = true
        alphaValue = 0.0

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.shadowBlurRadius = 24
        self.shadow = shadow

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.appearance = NSAppearance(named: .vibrantDark)
        visualEffectView.wantsLayer = true
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false

        if let layer = visualEffectView.layer {
            layer.cornerRadius = 18
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            layer.borderWidth = 0.5
        }

        // Dark scrim backdrop guarantees high-contrast legibility against bright backgrounds
        scrimView.wantsLayer = true
        scrimView.layer?.backgroundColor = NSColor(deviceWhite: 0.05, alpha: 0.75).cgColor
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

        // Balanced 2-column table grid (11 rows each, perfectly aligned horizontally)
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 38
        grid.rowSpacing = 8

        let compactPairs: [(col1: (key: String, desc: String), col2: (key: String, desc: String))] = [
            (("P", "Pick"), ("Z", "100% Zoom / Pan")),
            (("X", "Reject"), ("S", "Split compare")),
            (("U", "Unflag"), ("H", "RGB Histogram")),
            (("1 – 5", "Rating"), ("O", "Clipping warning")),
            (("0", "Clear rating"), ("I", "EXIF Info")),
            (("6 – 9", "Color label"), ("Return", "Slideshow")),
            (("C", "Auto-advance"), ("+ / -", "Slideshow speed")),
            (("E", "Export picks"), ("\\", "Cycle filter")),
            (("R / L", "Rotate 90°"), ("⇧ ⌫", "Purge rejects")),
            (("⌫", "Trash photo"), ("Space", "Next")),
            (("F", "Full screen"), ("?", "Shortcuts guide"))
        ]

        for pair in compactPairs {
            let rowCell1 = makeCompactRow(key: pair.col1.key, desc: pair.col1.desc)
            let rowCell2 = makeCompactRow(key: pair.col2.key, desc: pair.col2.desc)
            grid.addRow(with: [rowCell1, rowCell2])
        }

        grid.column(at: 0).width = 175
        grid.column(at: 1).width = 185

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
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false

        let keycap = makeKeycap(text: key)
        row.addArrangedSubview(keycap)

        let descLabel = NSTextField(labelWithString: desc)
        descLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        descLabel.textColor = NSColor(white: 0.90, alpha: 1.0)
        descLabel.lineBreakMode = .byClipping
        row.addArrangedSubview(descLabel)

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
        grid.columnSpacing = 34
        grid.rowSpacing = 14

        // Section Sub-headers Row
        let h1 = makeSectionSubHeader(title: "CULLING & XMP SYNC")
        let h2 = makeSectionSubHeader(title: "INSPECTION & TONAL TOOLS")
        let h3 = makeSectionSubHeader(title: "WORKFLOW & OUTPUT")
        grid.addRow(with: [h1, h2, h3])

        // 6 Matched Table Rows across all 3 functional domains
        let rowsData: [(
            c1: (key: String, title: String, desc: String),
            c2: (key: String, title: String, desc: String),
            c3: (key: String, title: String, desc: String)
        )] = [
            (
                ("P", "Pick (Keeper)", "Flags photo as keeper. Writes crs:PickStatus to Adobe XMP sidecar."),
                ("Z", "100% Pixel Peep", "Instant 1:1 sensor inspection centered at cursor. Drag to pan."),
                ("Return", "Slideshow", "Automated timed presentation. Any key or click stops it.")
            ),
            (
                ("X", "Reject (Trash)", "Marks for purge. Writes xmp:Rating=-1 to sidecar."),
                ("S", "2-Up Compare", "Split-screen burst compare with next frame. Synchronous 1:1 pan."),
                ("+ / -", "Slideshow Speed", "Live interval stepping (1s, 2s, 3s, 5s, 8s... up to 30s).")
            ),
            (
                ("U", "Unflag", "Clears pick/reject flags back to neutral in sidecar."),
                ("H", "RGB Histogram", "Hardware 256-bin RGB & Rec. 709 Luminance curve overlay."),
                ("R / L", "Lossless Rotation", "R or ]: 90° CW, L or [: 90° CCW via lossless EXIF rewrite.")
            ),
            (
                ("1 – 5", "Star Ratings", "Rates 1 to 5 stars (xmp:Rating). 0 clears stars."),
                ("O", "Clipping Warnings", "Pulsing blinkies: Red for blown highlights, Blue for shadows."),
                ("E", "Quick Export", "Copies all Picks (or current photo) to ./Picks with sound chime.")
            ),
            (
                ("6 – 9", "Color Labels", "6: Red, 7: Yellow, 8: Green, 9: Blue in Adobe XMP."),
                ("I", "EXIF Info HUD", "Camera body, lens, shutter, aperture, ISO, and focal length."),
                ("⌫", "Trash Photo", "Moves active shot (and RAW + XMP pair) to macOS Trash.")
            ),
            (
                ("C", "Auto-Advance", "Speed culling: automatically advances after rating or flag."),
                ("\\", "Cycle Filters", "All ➔ Hide Rejects ➔ Picks Only ➔ Rejects Only ➔ Stars."),
                ("⇧ ⌫", "Purge Rejects", "Batch-moves all rejected (X) photos to macOS Trash in one go.")
            )
        ]

        for item in rowsData {
            let cell1 = makeVerboseRow(key: item.c1.key, title: item.c1.title, desc: item.c1.desc)
            let cell2 = makeVerboseRow(key: item.c2.key, title: item.c2.title, desc: item.c2.desc)
            let cell3 = makeVerboseRow(key: item.c3.key, title: item.c3.title, desc: item.c3.desc)
            grid.addRow(with: [cell1, cell2, cell3])
        }

        // Explicit generous 265pt width per column gives ample breathing room
        grid.column(at: 0).width = 265
        grid.column(at: 1).width = 265
        grid.column(at: 2).width = 265

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
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor(white: 0.50, alpha: 1.0),
                .kern: 0.6
            ]
        )
        label.attributedStringValue = attr
        return label
    }

    private func makeSectionSubHeader(title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        let attr = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: NSColor(white: 0.60, alpha: 1.0),
                .kern: 0.5
            ]
        )
        label.attributedStringValue = attr
        return label
    }

    private func makeKeycap(text: String) -> NSView {
        let keycap = NSView()
        keycap.wantsLayer = true
        // Refined monochromatic macOS keycap (Apple HIG Dark)
        keycap.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        keycap.layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor
        keycap.layer?.borderWidth = 0.5
        keycap.layer?.cornerRadius = 5
        keycap.layer?.cornerCurve = .continuous
        keycap.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = NSTextField(labelWithString: text)
        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        keyLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        keyLabel.alignment = .center
        keyLabel.translatesAutoresizingMaskIntoConstraints = false

        keycap.addSubview(keyLabel)
        NSLayoutConstraint.activate([
            keycap.widthAnchor.constraint(equalToConstant: 46),
            keycap.heightAnchor.constraint(equalToConstant: 21),
            keyLabel.centerXAnchor.constraint(equalTo: keycap.centerXAnchor),
            keyLabel.centerYAnchor.constraint(equalTo: keycap.centerYAnchor)
        ])
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
        titleLabel.textColor = NSColor(white: 0.95, alpha: 1.0)
        descCol.addArrangedSubview(titleLabel)

        // Apple Secondary Hierarchy: secondaryLabelColor
        let detailLabel = NSTextField(wrappingLabelWithString: desc)
        detailLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = NSColor(white: 0.65, alpha: 1.0)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descCol.addArrangedSubview(detailLabel)

        row.addArrangedSubview(descCol)
        return row
    }

    // MARK: - Interactive Visual Clue Pill

    private func setupCluePill() {
        cluePill.wantsLayer = true
        cluePill.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        cluePill.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        cluePill.layer?.borderWidth = 0.5
        cluePill.layer?.cornerRadius = 11
        cluePill.layer?.cornerCurve = .continuous
        cluePill.translatesAutoresizingMaskIntoConstraints = false

        clueLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        clueLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
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
        if isExpanded {
            clueLabel.stringValue = "␣ Space or Click to collapse ▴"
            cluePill.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.12).cgColor
            cluePill.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
            clueLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        } else {
            clueLabel.stringValue = "␣ Space or Click to expand details ▾"
            cluePill.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
            cluePill.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
            clueLabel.textColor = NSColor(white: 0.70, alpha: 1.0)
        }
    }

    // MARK: - Interactive Expand / Collapse Toggle

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

    public override func mouseDown(with event: NSEvent) {
        toggleExpansion()
    }

    public override func layout() {
        super.layout()
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
            NSColor.black.setFill()
            path.fill()
            return true
        }
        maskImage.capInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        maskImage.resizingMode = .stretch
        visualEffectView.maskImage = maskImage
    }

    // MARK: - Presentation & Lifecycle

    public func toggle() {
        if alphaValue > 0.0 {
            dismiss()
        } else {
            present()
        }
    }

    public func present() {
        dismissTimer?.invalidate()
        if isExpanded {
            isExpanded = false
            compactContainer.isHidden = false
            expandedContainer.isHidden = true
            updateClueLabel()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1.0
        }
        resetDismissTimer(timeout: 6.0)
    }

    public func dismiss() {
        dismissTimer?.invalidate()
        guard alphaValue > 0.0 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            self.animator().alphaValue = 0.0
        }
    }

    private func resetDismissTimer(timeout: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isExpanded else { return }
                self.dismiss()
            }
        }
    }

    deinit {
        dismissTimer?.invalidate()
    }
}
