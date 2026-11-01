import AppKit
import CoreGraphics
import QuartzCore

/// High-performance floating filmstrip scrubber card adhering to the Glance HIG.
/// Built strictly on `ThemedGlassCardView(cornerRadius: 16)` floating just above
/// the bottom telemetry HUD. Displays an asynchronous hardware-decoded micro-thumbnail
/// ring buffer across the active playlist with high-contrast active selection rim,
/// visual burst grouping brackets, hero badges, live culling status badges,
/// and smooth two-finger trackpad inertial scrolling & scrubbing.
@MainActor
public final class FilmstripHudView: ThemedGlassCardView {
    public var onSelectIndex: ((Int) -> Void)?

    public private(set) var isPresented: Bool = false
    public private(set) var isPinned: Bool = false

    private var items: [SlideItem] = []
    private var currentIndex: Int = 0
    private var cullingData: [String: CullingMetadata] = [:]
    private var burstCache: [Int: BurstBreadcrumbInfo?] = [:]

    // Scrolling container
    private let scrollView = NSScrollView()
    private let canvasView = FilmstripCanvasView()

    // Hover auto-dismiss timer when not pinned
    private var autoDismissTimer: Timer?

    public init() {
        super.init(cornerRadius: 16.0)
        setupFilmstripView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFilmstripView()
    }

    private func setupFilmstripView() {
        wantsLayer = true
        alphaValue = 0.0
        isHidden = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.hud = self
        scrollView.documentView = canvasView

        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8)
        ])

        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.canvasView.updateVisibleCells()
            }
        }
    }

    // MARK: - Presentation & Visibility Lifecycle

    public func togglePinned() {
        if isPinned && isPresented {
            dismiss(animated: true)
            isPinned = false
        } else {
            isPinned = true
            present(animated: true)
        }
    }

    public func present(pinned: Bool = true, animated: Bool = true) {
        if pinned {
            isPinned = true
            autoDismissTimer?.invalidate()
            autoDismissTimer = nil
        }

        guard !isPresented else { return }
        isPresented = true
        isHidden = false

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.20
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            }
        } else {
            alphaValue = 1.0
        }

        scrollToActiveIndex(animated: animated)
    }

    public func dismiss(animated: Bool = true) {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        isPinned = false

        guard isPresented else { return }
        isPresented = false

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    if let self = self, !self.isPresented {
                        self.isHidden = true
                    }
                }
            })
        } else {
            alphaValue = 0.0
            isHidden = true
        }
    }

    public func pulseFromHover() {
        if !isPresented {
            present(pinned: false, animated: true)
        }
        if !isPinned {
            scheduleAutoDismiss()
        }
    }

    public func handleMouseExited() {
        if !isPinned && isPresented {
            scheduleAutoDismiss(delay: 0.6)
        }
    }

    public func scheduleAutoDismiss(delay: TimeInterval = 1.8) {
        guard !isPinned else { return }
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, !self.isPinned else { return }
                self.dismiss(animated: true)
            }
        }
    }

    public func cancelAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    // MARK: - Data Synchronization

    public func update(
        items: [SlideItem],
        currentIndex: Int,
        cullingData: [String: CullingMetadata],
        burstCache: [Int: BurstBreadcrumbInfo?]
    ) {
        self.items = items
        self.currentIndex = max(0, min(currentIndex, max(0, items.count - 1)))
        self.cullingData = cullingData
        self.burstCache = burstCache

        canvasView.reloadData(
            items: items,
            currentIndex: self.currentIndex,
            cullingData: cullingData,
            burstCache: burstCache
        )

        if isPresented {
            scrollToActiveIndex(animated: true)
        }
    }

    public func updateActiveIndex(_ newIndex: Int) {
        guard newIndex != currentIndex, newIndex >= 0, newIndex < items.count else { return }
        self.currentIndex = newIndex
        canvasView.updateActiveSelection(newIndex: newIndex)
        if isPresented {
            scrollToActiveIndex(animated: true)
        }
    }

    public func updateCulling(for itemId: String, metadata: CullingMetadata) {
        self.cullingData[itemId] = metadata
        canvasView.updateCulling(for: itemId, metadata: metadata)
    }

    public func updateBurstCache(_ newBurstCache: [Int: BurstBreadcrumbInfo?]) {
        self.burstCache = newBurstCache
        canvasView.updateBurstCache(newBurstCache)
    }

    // MARK: - Scrolling & Auto-Centering

    public func scrollToActiveIndex(animated: Bool = true) {
        guard !items.isEmpty else { return }
        let cellWidth: CGFloat = 76.0
        let spacing: CGFloat = 8.0
        let stride = cellWidth + spacing
        let leftInset: CGFloat = 16.0

        let cellCenterX = leftInset + CGFloat(currentIndex) * stride + (cellWidth / 2.0)
        let visibleWidth = scrollView.contentView.bounds.width
        guard visibleWidth > 0 else { return }

        let targetX = cellCenterX - (visibleWidth / 2.0)
        let totalWidth = canvasView.frame.width
        let maxX = max(0, totalWidth - visibleWidth)
        let clampedX = max(0, min(targetX, maxX))

        let targetPoint = NSPoint(x: clampedX, y: 0)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.scrollView.contentView.animator().setBoundsOrigin(targetPoint)
            }
        } else {
            self.scrollView.contentView.setBoundsOrigin(targetPoint)
        }

        canvasView.updateVisibleCells()
    }

    public func handleScrollWheel(with event: NSEvent) {
        scrollView.scrollWheel(with: event)
        if !isPinned {
            pulseFromHover()
        }
    }

    public override func applyTheme() {
        super.applyTheme()
        canvasView.applyTheme()
    }
}

// MARK: - Filmstrip Canvas View (Virtualized Lightweight Recycling)

@MainActor
final class FilmstripCanvasView: NSView {
    weak var hud: FilmstripHudView?

    private var items: [SlideItem] = []
    private var currentIndex: Int = 0
    private var cullingData: [String: CullingMetadata] = [:]
    private var burstCache: [Int: BurstBreadcrumbInfo?] = [:]

    private let cellWidth: CGFloat = 76.0
    private let cellHeight: CGFloat = 52.0
    private let spacing: CGFloat = 8.0
    private let leftInset: CGFloat = 16.0
    private let rightInset: CGFloat = 16.0

    private var activeCells: [Int: FilmstripThumbnailCell] = [:]
    private var cellPool: [FilmstripThumbnailCell] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var isFlipped: Bool {
        return true
    }

    func reloadData(
        items: [SlideItem],
        currentIndex: Int,
        cullingData: [String: CullingMetadata],
        burstCache: [Int: BurstBreadcrumbInfo?]
    ) {
        self.items = items
        self.currentIndex = currentIndex
        self.cullingData = cullingData
        self.burstCache = burstCache

        let count = items.count
        let totalW = count == 0
            ? 320.0
            : (leftInset + CGFloat(count) * (cellWidth + spacing) - spacing + rightInset)

        let targetFrame = NSRect(x: 0, y: 0, width: max(320.0, totalW), height: 76.0)
        if frame != targetFrame {
            frame = targetFrame
        }

        // Return all existing cells to pool
        for (_, cell) in activeCells {
            cell.removeFromSuperview()
            cellPool.append(cell)
        }
        activeCells.removeAll()

        updateVisibleCells()
    }

    func updateActiveSelection(newIndex: Int) {
        let oldIndex = currentIndex
        self.currentIndex = newIndex

        if let oldCell = activeCells[oldIndex] {
            oldCell.setIsActive(false)
        }
        if let newCell = activeCells[newIndex] {
            newCell.setIsActive(true)
        }
    }

    func updateCulling(for itemId: String, metadata: CullingMetadata) {
        self.cullingData[itemId] = metadata
        for (idx, cell) in activeCells {
            if idx < items.count && items[idx].id == itemId {
                cell.updateCulling(metadata)
            }
        }
    }

    func updateBurstCache(_ newCache: [Int: BurstBreadcrumbInfo?]) {
        self.burstCache = newCache
        for (idx, cell) in activeCells {
            let burstInfo = newCache[idx] ?? nil
            let isBurstStart = (burstInfo?.indexInBurst == 1)
            let isBurstEnd = (burstInfo != nil && burstInfo!.indexInBurst == burstInfo!.totalInBurst)
            cell.updateBurst(
                burstInfo: burstInfo,
                isBurstStart: isBurstStart,
                isBurstEnd: isBurstEnd
            )
        }
    }

    func updateVisibleCells() {
        guard !items.isEmpty else { return }

        let stride = cellWidth + spacing
        let vis = visibleRect

        let firstIndex = max(0, Int(floor((vis.minX - leftInset) / stride)) - 1)
        let lastIndex = min(items.count - 1, Int(ceil((vis.maxX - leftInset) / stride)) + 1)

        // Recycle offscreen cells
        var toRemove: [Int] = []
        for (idx, cell) in activeCells {
            if idx < firstIndex || idx > lastIndex {
                cell.removeFromSuperview()
                cellPool.append(cell)
                toRemove.append(idx)
            }
        }
        for idx in toRemove {
            activeCells.removeValue(forKey: idx)
        }

        // Populate visible cells
        for idx in firstIndex...lastIndex {
            let cellX = leftInset + CGFloat(idx) * stride
            let cellFrame = NSRect(x: cellX, y: 12.0, width: cellWidth, height: cellHeight)

            if let existing = activeCells[idx] {
                existing.frame = cellFrame
            } else {
                let cell: FilmstripThumbnailCell
                if !cellPool.isEmpty {
                    cell = cellPool.removeLast()
                } else {
                    cell = FilmstripThumbnailCell()
                }

                cell.frame = cellFrame
                addSubview(cell)
                activeCells[idx] = cell

                let item = items[idx]
                let meta = cullingData[item.id] ?? CullingMetadata()
                let burst = burstCache[idx] ?? nil
                let isBurstStart = (burst?.indexInBurst == 1)
                let isBurstEnd = (burst != nil && burst!.indexInBurst == burst!.totalInBurst)

                cell.configure(
                    index: idx,
                    item: item,
                    culling: meta,
                    burstInfo: burst,
                    isBurstStart: isBurstStart,
                    isBurstEnd: isBurstEnd,
                    isActive: (idx == currentIndex)
                )
            }
        }
    }

    func applyTheme() {
        for (_, cell) in activeCells {
            cell.applyTheme()
        }
        for cell in cellPool {
            cell.applyTheme()
        }
    }

    // MARK: - Scrubbing & Mouse Interaction

    private func indexForPoint(_ point: NSPoint) -> Int? {
        let stride = cellWidth + spacing
        let relX = point.x - leftInset
        guard relX >= 0 else { return 0 }
        let rawIdx = Int(relX / stride)
        guard rawIdx >= 0 && rawIdx < items.count else { return nil }
        return rawIdx
    }

    override func mouseDown(with event: NSEvent) {
        hud?.cancelAutoDismiss()
        let pt = convert(event.locationInWindow, from: nil)
        if let idx = indexForPoint(pt) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            hud?.onSelectIndex?(idx)
            updateActiveSelection(newIndex: idx)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        hud?.cancelAutoDismiss()
        let pt = convert(event.locationInWindow, from: nil)
        if let idx = indexForPoint(pt), idx != currentIndex {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            hud?.onSelectIndex?(idx)
            updateActiveSelection(newIndex: idx)
        }
    }

    override func mouseUp(with event: NSEvent) {
        hud?.scheduleAutoDismiss()
    }
}

// MARK: - Filmstrip Thumbnail Cell View

@MainActor
final class FilmstripThumbnailCell: NSView {
    public private(set) var representedIndex: Int = -1
    public private(set) var representedItemId: String = ""

    private let imageLayer = CALayer()
    private let selectionRimLayer = CALayer()
    private let burstBracketLayer = CAShapeLayer()
    private let heroBadgeLayer = CATextLayer()
    private let pickBadgeLayer = CATextLayer()
    private let ratingBadgeLayer = CATextLayer()
    private let colorBarLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = false

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        // 1. Thumbnail Image Layer
        imageLayer.cornerCurve = .continuous
        imageLayer.cornerRadius = 6.0
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.backgroundColor = NSColor.black.withAlphaComponent(0.40).cgColor
        imageLayer.borderWidth = 0.5
        imageLayer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.addSublayer(imageLayer)

        // 2. High-Contrast Semantic Selection Rim (Cyan #00D2FF)
        selectionRimLayer.cornerCurve = .continuous
        selectionRimLayer.cornerRadius = 8.0
        selectionRimLayer.borderWidth = 2.5
        selectionRimLayer.borderColor = NSColor.systemCyan.cgColor
        selectionRimLayer.shadowColor = NSColor.systemCyan.withAlphaComponent(0.70).cgColor
        selectionRimLayer.shadowRadius = 5.0
        selectionRimLayer.shadowOpacity = 1.0
        selectionRimLayer.shadowOffset = .zero
        selectionRimLayer.isHidden = true
        layer?.addSublayer(selectionRimLayer)

        // 3. Visual Burst Bracket Connecting Adjacent Sibling Shots
        burstBracketLayer.strokeColor = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.20, alpha: 0.90).cgColor
        burstBracketLayer.fillColor = nil
        burstBracketLayer.lineWidth = 2.0
        burstBracketLayer.lineCap = .round
        burstBracketLayer.lineJoin = .round
        burstBracketLayer.isHidden = true
        layer?.addSublayer(burstBracketLayer)

        // 4. Hero Micro-Badge (👑)
        heroBadgeLayer.string = "👑"
        heroBadgeLayer.fontSize = 11.0
        heroBadgeLayer.alignmentMode = .center
        heroBadgeLayer.contentsScale = scale
        heroBadgeLayer.shadowColor = NSColor.black.cgColor
        heroBadgeLayer.shadowRadius = 2.0
        heroBadgeLayer.shadowOpacity = 0.9
        heroBadgeLayer.shadowOffset = CGSize(width: 0, height: -1)
        heroBadgeLayer.isHidden = true
        layer?.addSublayer(heroBadgeLayer)

        // 5. Semantic Pick / Reject Status Badge (✓ green / ✕ red)
        pickBadgeLayer.fontSize = 10.0
        pickBadgeLayer.alignmentMode = .center
        pickBadgeLayer.contentsScale = scale
        pickBadgeLayer.cornerRadius = 7.0
        pickBadgeLayer.cornerCurve = .continuous
        pickBadgeLayer.masksToBounds = true
        pickBadgeLayer.shadowColor = NSColor.black.cgColor
        pickBadgeLayer.shadowRadius = 2.0
        pickBadgeLayer.shadowOpacity = 0.8
        pickBadgeLayer.shadowOffset = CGSize(width: 0, height: -1)
        pickBadgeLayer.isHidden = true
        layer?.addSublayer(pickBadgeLayer)

        // 6. Star Rating Micro-Badge (★)
        ratingBadgeLayer.fontSize = 9.0
        ratingBadgeLayer.foregroundColor = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 1.0).cgColor
        ratingBadgeLayer.alignmentMode = .center
        ratingBadgeLayer.contentsScale = scale
        ratingBadgeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        ratingBadgeLayer.cornerRadius = 4.0
        ratingBadgeLayer.cornerCurve = .continuous
        ratingBadgeLayer.masksToBounds = true
        ratingBadgeLayer.isHidden = true
        layer?.addSublayer(ratingBadgeLayer)

        // 7. Adobe Color Label Bottom Bar
        colorBarLayer.cornerCurve = .continuous
        colorBarLayer.cornerRadius = 1.5
        colorBarLayer.masksToBounds = true
        colorBarLayer.isHidden = true
        layer?.addSublayer(colorBarLayer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let w = bounds.width
        let h = bounds.height

        // Thumbnail occupies lower portion to leave top room for burst brackets
        let thumbFrame = CGRect(x: 0, y: 0, width: w, height: h)
        imageLayer.frame = thumbFrame

        let rimOutset: CGFloat = 2.0
        selectionRimLayer.frame = CGRect(
            x: -rimOutset,
            y: -rimOutset,
            width: w + rimOutset * 2,
            height: h + rimOutset * 2
        )

        // Pick badge in top-left
        pickBadgeLayer.frame = CGRect(x: 3, y: h - 17, width: 14, height: 14)

        // Hero badge in top-right
        heroBadgeLayer.frame = CGRect(x: w - 18, y: h - 16, width: 16, height: 16)

        // Rating in bottom-left
        ratingBadgeLayer.frame = CGRect(x: 3, y: 3, width: 18, height: 12)

        // Color bar across bottom edge
        colorBarLayer.frame = CGRect(x: 0, y: 0, width: w, height: 3.5)

        CATransaction.commit()
    }

    func configure(
        index: Int,
        item: SlideItem,
        culling: CullingMetadata,
        burstInfo: BurstBreadcrumbInfo?,
        isBurstStart: Bool,
        isBurstEnd: Bool,
        isActive: Bool
    ) {
        self.representedIndex = index
        self.representedItemId = item.id

        setIsActive(isActive)
        updateCulling(culling)
        updateBurst(burstInfo: burstInfo, isBurstStart: isBurstStart, isBurstEnd: isBurstEnd)

        // Load thumbnail asynchronously without blocking main thread
        let thumbURL = item.url
        if let cached = MicroThumbnailEngine.shared.cachedThumbnail(for: thumbURL) {
            imageLayer.contents = cached
        } else {
            imageLayer.contents = nil
            MicroThumbnailEngine.shared.loadThumbnail(for: thumbURL) { [weak self] image in
                MainActor.assumeIsolated {
                    guard let self = self, self.representedIndex == index, self.representedItemId == item.id else { return }
                    self.imageLayer.contents = image
                }
            }
        }
    }

    func setIsActive(_ active: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionRimLayer.isHidden = !active
        CATransaction.commit()
    }

    func updateCulling(_ culling: CullingMetadata) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 1. Pick / Reject Status
        switch culling.pick {
        case .pick:
            pickBadgeLayer.string = "✓"
            pickBadgeLayer.backgroundColor = NSColor.systemGreen.cgColor
            pickBadgeLayer.foregroundColor = NSColor.white.cgColor
            pickBadgeLayer.isHidden = false
            imageLayer.opacity = 1.0
        case .reject:
            pickBadgeLayer.string = "✕"
            pickBadgeLayer.backgroundColor = NSColor.systemRed.cgColor
            pickBadgeLayer.foregroundColor = NSColor.white.cgColor
            pickBadgeLayer.isHidden = false
            imageLayer.opacity = 0.40 // Dim reject thumbnails
        case .unflagged:
            pickBadgeLayer.isHidden = true
            imageLayer.opacity = 1.0
        }

        // 2. Star Rating
        if culling.rating > 0 {
            ratingBadgeLayer.string = "★\(culling.rating)"
            ratingBadgeLayer.isHidden = false
        } else {
            ratingBadgeLayer.isHidden = true
        }

        // 3. Adobe Color Label Bar
        switch culling.color {
        case .none:
            colorBarLayer.isHidden = true
        case .red:
            colorBarLayer.backgroundColor = NSColor.systemRed.cgColor
            colorBarLayer.isHidden = false
        case .yellow:
            colorBarLayer.backgroundColor = NSColor.systemYellow.cgColor
            colorBarLayer.isHidden = false
        case .green:
            colorBarLayer.backgroundColor = NSColor.systemGreen.cgColor
            colorBarLayer.isHidden = false
        case .blue:
            colorBarLayer.backgroundColor = NSColor.systemBlue.cgColor
            colorBarLayer.isHidden = false
        }

        CATransaction.commit()
    }

    func updateBurst(burstInfo: BurstBreadcrumbInfo?, isBurstStart: Bool, isBurstEnd: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        guard let burst = burstInfo, burst.totalInBurst > 1 else {
            burstBracketLayer.isHidden = true
            heroBadgeLayer.isHidden = true
            CATransaction.commit()
            return
        }

        heroBadgeLayer.isHidden = !burst.isHero

        // Build burst bracket shape
        let path = CGMutablePath()
        let w = bounds.width
        let y: CGFloat = bounds.height + 4.0

        if isBurstStart && isBurstEnd {
            // Standalone single-frame burst item
            path.move(to: CGPoint(x: 2, y: bounds.height - 2))
            path.addLine(to: CGPoint(x: 2, y: y))
            path.addLine(to: CGPoint(x: w - 2, y: y))
            path.addLine(to: CGPoint(x: w - 2, y: bounds.height - 2))
        } else if isBurstStart {
            // Burst start bracket: ┌───
            path.move(to: CGPoint(x: 2, y: bounds.height - 2))
            path.addLine(to: CGPoint(x: 2, y: y))
            path.addLine(to: CGPoint(x: w + 8, y: y))
        } else if isBurstEnd {
            // Burst end bracket: ───┐
            path.move(to: CGPoint(x: -8, y: y))
            path.addLine(to: CGPoint(x: w - 2, y: y))
            path.addLine(to: CGPoint(x: w - 2, y: bounds.height - 2))
        } else {
            // Middle burst frame: continuous line across
            path.move(to: CGPoint(x: -8, y: y))
            path.addLine(to: CGPoint(x: w + 8, y: y))
        }

        burstBracketLayer.path = path
        burstBracketLayer.isHidden = false

        CATransaction.commit()
    }

    func applyTheme() {
        let theme = ThemeManager.shared
        imageLayer.borderColor = theme.isDark
            ? NSColor.white.withAlphaComponent(0.12).cgColor
            : NSColor.black.withAlphaComponent(0.12).cgColor
    }
}
