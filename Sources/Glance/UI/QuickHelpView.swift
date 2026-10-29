import AppKit

/// Apple Pro frosted-glass shortcuts cheatsheet.
/// Follows Apple Human Interface Guidelines for dark HUD hierarchy:
/// monochromatic keycaps, unified typography (labelColor, secondaryLabelColor),
/// and generous edge margins so text never touches card borders.
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
        rootStack.spacing = 16
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(rootStack)

        // HARD AUTO-LAYOUT CONSTRAINTS: 36pt left/right and 28pt/24pt top/bottom margins
        // This guarantees content CANNOT touch the rounded glass edges under any circumstance.
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

    // MARK: - Compact Mode Layout

    private func setupCompactLayout() {
        compactContainer.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = makeSectionHeader(title: "KEYBOARD SHORTCUTS")
        stack.addArrangedSubview(header)

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 38
        columns.translatesAutoresizingMaskIntoConstraints = false

        // Col 1: Culling
        let col1 = NSStackView()
        col1.orientation = .vertical
        col1.alignment = .leading
        col1.spacing = 7.5
        col1.translatesAutoresizingMaskIntoConstraints = false
        col1.addArrangedSubview(makeCompactRow(key: "P", desc: "Pick"))
        col1.addArrangedSubview(makeCompactRow(key: "X", desc: "Reject"))
        col1.addArrangedSubview(makeCompactRow(key: "U", desc: "Unflag"))
        col1.addArrangedSubview(makeCompactRow(key: "1 – 5", desc: "Rating"))
        col1.addArrangedSubview(makeCompactRow(key: "0", desc: "Clear rating"))
        col1.addArrangedSubview(makeCompactRow(key: "6 – 9", desc: "Color label"))
        col1.addArrangedSubview(makeCompactRow(key: "C", desc: "Auto-advance"))
        col1.addArrangedSubview(makeCompactRow(key: "E", desc: "Export picks"))
        col1.addArrangedSubview(makeCompactRow(key: "R / L", desc: "Rotate 90°"))
        columns.addArrangedSubview(col1)

        // Col 2: Navigation & Review
        let col2 = NSStackView()
        col2.orientation = .vertical
        col2.alignment = .leading
        col2.spacing = 7.5
        col2.translatesAutoresizingMaskIntoConstraints = false
        col2.addArrangedSubview(makeCompactRow(key: "Z", desc: "100% Zoom / Pan"))
        col2.addArrangedSubview(makeCompactRow(key: "S", desc: "Split compare"))
        col2.addArrangedSubview(makeCompactRow(key: "H", desc: "RGB Histogram"))
        col2.addArrangedSubview(makeCompactRow(key: "O", desc: "Clipping warning"))
        col2.addArrangedSubview(makeCompactRow(key: "I", desc: "EXIF Info"))
        col2.addArrangedSubview(makeCompactRow(key: "Return", desc: "Slideshow"))
        col2.addArrangedSubview(makeCompactRow(key: "+ / -", desc: "Slideshow speed"))
        col2.addArrangedSubview(makeCompactRow(key: "\\", desc: "Cycle filter"))
        col2.addArrangedSubview(makeCompactRow(key: "⇧ ⌫", desc: "Purge rejects"))
        col2.addArrangedSubview(makeCompactRow(key: "Space", desc: "Next"))
        col2.addArrangedSubview(makeCompactRow(key: "F", desc: "Full screen"))
        col2.addArrangedSubview(makeCompactRow(key: "?", desc: "Shortcuts"))
        columns.addArrangedSubview(col2)

        stack.addArrangedSubview(columns)
        compactContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: compactContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: compactContainer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: compactContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: compactContainer.trailingAnchor),
            col2.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
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

    // MARK: - Expanded Mode Layout (Consistent Apple Dark Hierarchy)

    private func setupExpandedLayout() {
        expandedContainer.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = makeSectionHeader(title: "DETAILED SHORTCUTS GUIDE")
        stack.addArrangedSubview(header)

        let cols = NSStackView()
        cols.orientation = .horizontal
        cols.alignment = .top
        cols.spacing = 32
        cols.translatesAutoresizingMaskIntoConstraints = false

        // Col 1: Culling & XMP
        let col1 = NSStackView()
        col1.orientation = .vertical
        col1.alignment = .leading
        col1.spacing = 10
        col1.translatesAutoresizingMaskIntoConstraints = false
        col1.addArrangedSubview(makeSectionSubHeader(title: "CULLING & XMP SYNC"))
        col1.addArrangedSubview(makeVerboseRow(key: "P", title: "Pick (Keeper)", desc: "Flags photo as keeper. Writes crs:PickStatus to Adobe XMP sidecar."))
        col1.addArrangedSubview(makeVerboseRow(key: "X", title: "Reject (Trash)", desc: "Marks for purge. Writes xmp:Rating=-1 to sidecar."))
        col1.addArrangedSubview(makeVerboseRow(key: "U", title: "Unflag", desc: "Clears pick/reject flags back to neutral."))
        col1.addArrangedSubview(makeVerboseRow(key: "1 – 5", title: "Star Ratings", desc: "Rates 1 to 5 stars (xmp:Rating). 0 clears stars."))
        col1.addArrangedSubview(makeVerboseRow(key: "6 – 9", title: "Color Labels", desc: "6: Red, 7: Yellow, 8: Green, 9: Blue in XMP."))
        col1.addArrangedSubview(makeVerboseRow(key: "C", title: "Auto-Advance", desc: "Speed culling: automatically advances after rating or flag."))
        cols.addArrangedSubview(col1)

        // Col 2: Inspection & Tonal Analysis
        let col2 = NSStackView()
        col2.orientation = .vertical
        col2.alignment = .leading
        col2.spacing = 10
        col2.translatesAutoresizingMaskIntoConstraints = false
        col2.addArrangedSubview(makeSectionSubHeader(title: "INSPECTION & TONAL TOOLS"))
        col2.addArrangedSubview(makeVerboseRow(key: "Z", title: "100% Pixel Peep", desc: "Instant 1:1 sensor inspection centered at cursor. Drag to pan."))
        col2.addArrangedSubview(makeVerboseRow(key: "S", title: "2-Up Compare", desc: "Split-screen burst compare with next frame. Synchronous 1:1 pan."))
        col2.addArrangedSubview(makeVerboseRow(key: "H", title: "RGB Histogram", desc: "Hardware 256-bin RGB & Rec. 709 Luminance curve overlay."))
        col2.addArrangedSubview(makeVerboseRow(key: "O", title: "Clipping Warnings", desc: "Pulsing blinkies: Red for blown highlights, Blue for shadows."))
        col2.addArrangedSubview(makeVerboseRow(key: "I", title: "EXIF Info HUD", desc: "Camera body, lens, shutter, aperture, ISO, and focal length."))
        col2.addArrangedSubview(makeVerboseRow(key: "\\", title: "Cycle Filters", desc: "All ➔ Hide Rejects ➔ Picks Only ➔ Rejects Only ➔ Stars."))
        cols.addArrangedSubview(col2)

        // Col 3: Workflow & Navigation
        let col3 = NSStackView()
        col3.orientation = .vertical
        col3.alignment = .leading
        col3.spacing = 10
        col3.translatesAutoresizingMaskIntoConstraints = false
        col3.addArrangedSubview(makeSectionSubHeader(title: "WORKFLOW & OUTPUT"))
        col3.addArrangedSubview(makeVerboseRow(key: "Return", title: "Slideshow", desc: "Automated timed presentation. Any key or click stops it."))
        col3.addArrangedSubview(makeVerboseRow(key: "+ / -", title: "Slideshow Speed", desc: "Live interval stepping (1s, 2s, 3s, 5s, 8s... up to 30s)."))
        col3.addArrangedSubview(makeVerboseRow(key: "R / L", title: "Lossless Rotation", desc: "R or ]: 90° CW, L or [: 90° CCW via lossless EXIF rewrite."))
        col3.addArrangedSubview(makeVerboseRow(key: "E", title: "Quick Export", desc: "Copies all Picks (or current photo) to ./Picks with sound chime."))
        col3.addArrangedSubview(makeVerboseRow(key: "⌫", title: "Trash Photo", desc: "Moves active shot (and RAW + XMP pair) to macOS Trash."))
        col3.addArrangedSubview(makeVerboseRow(key: "⇧ ⌫", title: "Purge Rejects", desc: "Batch-moves all rejected (X) photos to macOS Trash in one go."))
        cols.addArrangedSubview(col3)

        stack.addArrangedSubview(cols)
        expandedContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: expandedContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: expandedContainer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: expandedContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: expandedContainer.trailingAnchor),
            // Generous 265pt width per column gives ample breathing room for descriptions
            col1.widthAnchor.constraint(equalToConstant: 265),
            col2.widthAnchor.constraint(equalToConstant: 265),
            col3.widthAnchor.constraint(equalToConstant: 265)
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
        descCol.spacing = 2
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
