import AppKit

/// The split-screen comparison surface: original on the left of a draggable
/// divider, compressed on the right, both drawn at *exactly* the same place.
///
/// ## How registration is guaranteed
///
/// There is one geometry function, `imageRect()`, and both images are CALayers whose
/// `frame` is set from that single value in `updateGeometry()`. Neither layer has any
/// transform, offset or scale of its own, and neither ever sees the zoom or the pan
/// values - only the rect. The divider is not a second viewport: it is a `mask` on each
/// layer, expressed in that same rect's coordinate space. So the two sides cannot drift
/// apart at any zoom level, at any pan offset, or mid-drag; there is no second code path
/// for them to drift along.
///
/// Image space is the *original's* oriented pixel grid. A compressed result with
/// different pixel dimensions (`--max-dimension`) is stretched onto the same rect,
/// which is what the user will actually see when they use the file, so the comparison
/// stays honest rather than merely convenient.
///
/// Zoom of 1.0 means one image pixel per point. `fit` is clamped to at most 1.0, so a
/// small image is letterboxed at 100% rather than blown up.
@MainActor
final class CompareImageView: NSView {

    // MARK: - Tunables

    /// Below this the two sides are indistinguishable; above it, pointless.
    static let minZoomFloor: CGFloat = 0.1
    static let maxZoom: CGFloat = 16
    /// Half-width of the band around the divider line that grabs the drag.
    private let dividerGrabSlop: CGFloat = 11
    private let handleRadius: CGFloat = 17

    // MARK: - Content

    private(set) var imageSpaceSize = CGSize(width: 1, height: 1)
    private var hasAlpha = false

    /// 0 = divider hard left (all compressed), 1 = hard right (all original).
    /// Stored as a fraction so a window resize leaves it proportionally where it was.
    var dividerFraction: CGFloat = 0.5 {
        didSet {
            dividerFraction = min(max(dividerFraction, 0), 1)
            guard dividerFraction != oldValue else { return }
            updateGeometry()
            overlay.dividerFraction = dividerFraction
            window?.invalidateCursorRects(for: self)
        }
    }

    private(set) var zoom: CGFloat = 1
    /// The point of image space that sits at the centre of the view.
    private var center = CGPoint(x: 0.5, y: 0.5)
    /// True while the zoom is the fit-to-window value, so resizing keeps it fitted.
    private var isFitted = true

    var onZoomChanged: ((CGFloat) -> Void)?

    // MARK: - Subviews / layers

    private let imageHost = PassthroughView()
    private let overlay = CompareOverlayView()
    private let originalLayer = CALayer()
    private let compressedLayer = CALayer()
    private let originalMask = CALayer()
    private let compressedMask = CALayer()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        imageHost.wantsLayer = true
        imageHost.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageHost)
        addSubview(overlay)
        NSLayoutConstraint.activate([
            imageHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageHost.topAnchor.constraint(equalTo: topAnchor),
            imageHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for (layer, mask) in [(originalLayer, originalMask), (compressedLayer, compressedMask)] {
            layer.contentsGravity = .resize
            layer.minificationFilter = .trilinear
            layer.magnificationFilter = .linear
            layer.isOpaque = false
            layer.masksToBounds = false
            mask.backgroundColor = NSColor.black.cgColor
            layer.mask = mask
            imageHost.layer?.addSublayer(layer)
        }
        overlay.dividerFraction = dividerFraction
    }

    // MARK: - Loading

    /// `original` defines image space. `compressed` may be nil while it is still being
    /// computed - the original then shows across the whole width.
    func setImages(original: LoadedImage, compressed: LoadedImage?) {
        imageSpaceSize = original.nativeSize
        hasAlpha = original.hasAlpha || (compressed?.hasAlpha ?? false)
        withoutAnimation {
            originalLayer.contents = original.cgImage
            compressedLayer.contents = compressed?.cgImage
        }
        overlay.hasCompressed = compressed != nil
        if isFitted {
            zoom = fitZoom
            center = CGPoint(x: imageSpaceSize.width / 2, y: imageSpaceSize.height / 2)
        }
        clampCenter()
        updateGeometry()
        needsDisplay = true
        onZoomChanged?(zoom)
    }

    /// Drops both images and goes back to fitting whatever arrives next. The divider
    /// position is deliberately kept: it is the user's, not the file's.
    func reset() {
        withoutAnimation {
            originalLayer.contents = nil
            compressedLayer.contents = nil
        }
        overlay.hasCompressed = false
        overlay.leftCaption = ""
        overlay.rightCaption = ""
        imageSpaceSize = CGSize(width: 1, height: 1)
        hasAlpha = false
        isFitted = true
        zoom = 1
        center = CGPoint(x: 0.5, y: 0.5)
        updateGeometry()
        needsDisplay = true
    }

    func setCompressed(_ compressed: LoadedImage?) {
        hasAlpha = hasAlpha || (compressed?.hasAlpha ?? false)
        withoutAnimation { compressedLayer.contents = compressed?.cgImage }
        overlay.hasCompressed = compressed != nil
        updateGeometry()
        needsDisplay = true
    }

    var captions: (left: String, right: String) {
        get { (overlay.leftCaption, overlay.rightCaption) }
        set {
            overlay.leftCaption = newValue.left
            overlay.rightCaption = newValue.right
        }
    }

    // MARK: - Geometry

    var fitZoom: CGFloat {
        guard imageSpaceSize.width > 0, imageSpaceSize.height > 0 else { return 1 }
        let inset: CGFloat = 24 // a little air, so the edges are visibly edges
        let available = CGSize(width: max(bounds.width - inset, 1),
                               height: max(bounds.height - inset, 1))
        let raw = min(available.width / imageSpaceSize.width,
                      available.height / imageSpaceSize.height)
        // Never upscale on "fit": a 64 px icon filling a 900 pt window helps nobody.
        return min(raw, 1)
    }

    private var minZoom: CGFloat { min(CompareImageView.minZoomFloor, fitZoom) }

    /// The one place the on-screen rectangle of the image is decided.
    private func imageRect() -> CGRect {
        let width = imageSpaceSize.width * zoom
        let height = imageSpaceSize.height * zoom
        var x = bounds.midX - center.x * zoom
        var y = bounds.midY - center.y * zoom
        // At 100% and above, snap to the device pixel grid so pixels stay crisp.
        // Both layers take the same snapped rect, so registration is untouched.
        if zoom >= 1 {
            let scale = window?.backingScaleFactor ?? 2
            x = (x * scale).rounded() / scale
            y = (y * scale).rounded() / scale
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private var dividerX: CGFloat { bounds.minX + dividerFraction * bounds.width }

    private func updateGeometry() {
        let rect = imageRect()
        let split = min(max(dividerX - rect.minX, 0), rect.width)
        withoutAnimation {
            originalLayer.frame = rect
            compressedLayer.frame = rect
            originalLayer.bounds = CGRect(origin: .zero, size: rect.size)
            compressedLayer.bounds = CGRect(origin: .zero, size: rect.size)
            // Masks live in the masked layer's own coordinate space, which is the
            // same rect for both - so the seam is one number, not two.
            originalMask.frame = CGRect(x: 0, y: 0, width: split, height: rect.height)
            compressedMask.frame = CGRect(x: split, y: 0,
                                          width: rect.width - split, height: rect.height)
            let filter: CALayerContentsFilter = zoom >= 3 ? .nearest : .linear
            originalLayer.magnificationFilter = filter
            compressedLayer.magnificationFilter = filter
        }
        overlay.imageRect = rect
        needsDisplay = true
    }

    private func clampCenter() {
        let halfW = bounds.width / 2 / zoom
        let halfH = bounds.height / 2 / zoom
        if imageSpaceSize.width * zoom <= bounds.width {
            center.x = imageSpaceSize.width / 2
        } else {
            center.x = min(max(center.x, halfW), imageSpaceSize.width - halfW)
        }
        if imageSpaceSize.height * zoom <= bounds.height {
            center.y = imageSpaceSize.height / 2
        } else {
            center.y = min(max(center.y, halfH), imageSpaceSize.height - halfH)
        }
    }

    override func layout() {
        super.layout()
        if isFitted { zoom = fitZoom }
        clampCenter()
        updateGeometry()
        onZoomChanged?(zoom)
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        imageHost.layer?.contentsScale = scale
        updateGeometry()
    }

    // MARK: - Zoom API

    /// Zooms around a point in *view* coordinates, keeping whatever image pixel is
    /// under that point exactly where it is. Passing nil anchors on the view centre.
    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil, fitted: Bool = false) {
        let clamped = min(max(newZoom, minZoom), CompareImageView.maxZoom)
        let point = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let imagePoint = imagePoint(at: point)
        zoom = clamped
        isFitted = fitted
        // Solve for the centre that puts `imagePoint` back under `point`.
        center = CGPoint(x: imagePoint.x - (point.x - bounds.midX) / zoom,
                         y: imagePoint.y - (point.y - bounds.midY) / zoom)
        clampCenter()
        updateGeometry()
        onZoomChanged?(zoom)
        window?.invalidateCursorRects(for: self)
    }

    func zoomToFit() { setZoom(fitZoom, fitted: true) }
    func zoomToActualSize() { setZoom(1) }

    func stepZoom(_ factor: CGFloat) {
        setZoom(zoom * factor)
    }

    /// Fit <-> 100%, the double-click toggle.
    func toggleZoom(anchor: CGPoint? = nil) {
        if abs(zoom - 1) < 0.001 {
            zoomToFit()
        } else {
            setZoom(1, anchor: anchor)
        }
    }

    private func imagePoint(at viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: center.x + (viewPoint.x - bounds.midX) / zoom,
                y: center.y + (viewPoint.y - bounds.midY) / zoom)
    }

    private func pan(by delta: CGSize) {
        center.x -= delta.width / zoom
        center.y += delta.height / zoom
        clampCenter()
        updateGeometry()
    }

    private var isPannable: Bool {
        imageSpaceSize.width * zoom > bounds.width + 0.5
            || imageSpaceSize.height * zoom > bounds.height + 0.5
    }

    // MARK: - Events

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private enum Drag { case none, divider, pan }
    private var drag: Drag = .none

    private func isOnDivider(_ point: CGPoint) -> Bool {
        if abs(point.x - dividerX) <= dividerGrabSlop { return true }
        let handleCentre = CGPoint(x: dividerX, y: bounds.midY)
        return hypot(point.x - handleCentre.x, point.y - handleCentre.y) <= handleRadius
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            if isOnDivider(point) {
                dividerFraction = 0.5     // double-click the handle: recentre the split
            } else {
                toggleZoom(anchor: point)
            }
            drag = .none
            return
        }
        if isOnDivider(point) {
            drag = .divider
            dividerFraction = (point.x - bounds.minX) / max(bounds.width, 1)
        } else if isPannable {
            drag = .pan
            NSCursor.closedHand.push()
        } else {
            drag = .none
        }
    }

    override func mouseDragged(with event: NSEvent) {
        switch drag {
        case .divider:
            let point = convert(event.locationInWindow, from: nil)
            dividerFraction = (point.x - bounds.minX) / max(bounds.width, 1)
        case .pan:
            pan(by: CGSize(width: event.deltaX, height: -event.deltaY))
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if drag == .pan { NSCursor.pop() }
        drag = .none
    }

    override func scrollWheel(with event: NSEvent) {
        // Pinch arrives via magnify(with:); a plain two-finger scroll pans.
        guard isPannable else { return }
        pan(by: CGSize(width: event.scrollingDeltaX, height: -event.scrollingDeltaY))
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setZoom(zoom * (1 + event.magnification), anchor: point)
    }

    override func keyDown(with event: NSEvent) {
        // Arrow keys nudge the divider - the one control this window is really about -
        // with Shift for a coarse step. Everything else here is zoom.
        let fine: CGFloat = event.modifierFlags.contains(.shift) ? 0.1 : 0.02
        switch Int(event.keyCode) {
        case 123: dividerFraction -= fine; return   // left arrow
        case 124: dividerFraction += fine; return   // right arrow
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": stepZoom(1.25)
        case "-", "_": stepZoom(1 / 1.25)
        case "0":      zoomToFit()
        case "1":      zoomToActualSize()
        default:       super.keyDown(with: event)
        }
    }

    // MARK: - Accessibility
    //
    // The whole surface reports as one slider whose value is the divider position, so
    // it can be read and moved without a trackpad.

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityRoleDescription() -> String? { "comparison divider" }
    override func accessibilityLabel() -> String? { "Comparison divider" }
    override func accessibilityHelp() -> String? {
        "0 shows only the compressed result, 1 shows only the original."
    }
    override func accessibilityValue() -> Any? { NSNumber(value: Double(dividerFraction)) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0.0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 1.0) }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let number = accessibilityValue as? NSNumber else { return }
        dividerFraction = CGFloat(number.doubleValue)
    }

    override func accessibilityPerformIncrement() -> Bool {
        dividerFraction += 0.05
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        dividerFraction -= 0.05
        return true
    }

    override func resetCursorRects() {
        let band = NSRect(x: dividerX - dividerGrabSlop, y: 0,
                          width: dividerGrabSlop * 2, height: bounds.height)
        if isPannable {
            addCursorRect(bounds, cursor: .openHand)
        }
        addCursorRect(band.intersection(bounds), cursor: .resizeLeftRight)
    }

    // MARK: - Backdrop

    override func draw(_ dirtyRect: NSRect) {
        CompareStyle.backdrop.setFill()
        dirtyRect.fill()

        guard hasAlpha, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect().intersection(bounds)
        guard !rect.isNull, !rect.isEmpty else { return }
        context.saveGState()
        context.clip(to: rect)
        CompareStyle.drawCheckerboard(in: rect, context: context)
        context.restoreGState()
    }

    // MARK: - Helpers

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// MARK: - Overlay (divider, handle, captions)

/// Drawn above the image layers. Purely decorative: it never takes a mouse event,
/// so the whole surface behaves as one.
private final class CompareOverlayView: PassthroughView {

    var dividerFraction: CGFloat = 0.5 { didSet { needsDisplay = true } }
    /// Where the image actually is, so the captions hug it instead of floating in
    /// the letterbox when the image is smaller than the view.
    var imageRect: CGRect = .zero {
        didSet { if imageRect != oldValue { needsDisplay = true } }
    }
    var leftCaption = "" { didSet { needsDisplay = true } }
    var rightCaption = "" { didSet { needsDisplay = true } }
    var hasCompressed = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let x = (bounds.minX + dividerFraction * bounds.width).rounded()

        let anchor = captionAnchor()
        drawCaption(leftCaption, alignedLeft: true, anchor: anchor,
                    clip: NSRect(x: bounds.minX, y: 0, width: x - bounds.minX, height: bounds.height))
        if hasCompressed {
            drawCaption(rightCaption, alignedLeft: false, anchor: anchor,
                        clip: NSRect(x: x, y: 0, width: bounds.maxX - x, height: bounds.height))
        }

        // Line: a soft dark halo under a bright hairline, so it reads on any image.
        context.saveGState()
        NSColor.black.withAlphaComponent(0.22).setFill()
        NSRect(x: x - 2, y: bounds.minY, width: 4, height: bounds.height).fill()
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSRect(x: x - 0.75, y: bounds.minY, width: 1.5, height: bounds.height).fill()
        context.restoreGState()

        drawHandle(at: CGPoint(x: x, y: bounds.midY), context: context)
    }

    private func drawHandle(at point: CGPoint, context: CGContext) {
        let radius: CGFloat = 17
        let circle = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                                 width: radius * 2, height: radius * 2))
        context.saveGState()
        context.setShadow(offset: .zero, blur: 6,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor.white.withAlphaComponent(0.96).setFill()
        circle.fill()
        context.restoreGState()

        NSColor.black.withAlphaComponent(0.12).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        // Two chevrons: the affordance that says "this thing moves sideways".
        NSColor.black.withAlphaComponent(0.62).setStroke()
        for direction in [-1.0, 1.0] as [CGFloat] {
            let path = NSBezierPath()
            let tipX = point.x + direction * 8.5
            let baseX = point.x + direction * 3.5
            path.move(to: CGPoint(x: baseX, y: point.y + 4.5))
            path.line(to: CGPoint(x: tipX, y: point.y))
            path.line(to: CGPoint(x: baseX, y: point.y - 4.5))
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    /// Captions hug the image when there is room for both of them beside it, and fall
    /// back to the view's own corners when the image is too narrow to hold them apart.
    private func captionAnchor() -> NSRect {
        let rect = imageRect.intersection(bounds)
        guard !rect.isNull, rect.height >= 70 else { return bounds }
        let needed = captionSize(leftCaption).width + captionSize(rightCaption).width + 36
        return rect.width >= needed ? rect : bounds
    }

    private func captionSize(_ text: String) -> NSSize {
        guard !text.isEmpty else { return .zero }
        let size = (text as NSString).size(withAttributes: Self.captionAttributes)
        return NSSize(width: size.width + 14, height: size.height + 6)
    }

    private static let captionAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.95)
    ]

    private func drawCaption(_ text: String, alignedLeft: Bool, anchor: NSRect, clip: NSRect) {
        guard !text.isEmpty, clip.width > 12 else { return }
        let attributes = Self.captionAttributes
        let padding = NSSize(width: 7, height: 3)
        let chipSize = captionSize(text)
        let chipWidth = chipSize.width
        let chipHeight = chipSize.height
        let inset: CGFloat = 12
        let originX = alignedLeft ? anchor.minX + inset : anchor.maxX - inset - chipWidth
        let chip = NSRect(x: originX, y: anchor.maxY - inset - chipHeight,
                          width: chipWidth, height: chipHeight)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip).setClip()
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: NSPoint(x: chip.minX + padding.width,
                                            y: chip.minY + padding.height),
                                withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A view that draws but never takes a click.
class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Shared styling

@MainActor
enum CompareStyle {

    /// Neutral surround, a shade away from the window background so the letterboxed
    /// image still reads as an image and not as the window itself.
    static let backdrop = NSColor(name: nil) { appearance in
        appearance.isDarkAppearance ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)
    }

    static func drawCheckerboard(in rect: CGRect, context: CGContext) {
        let square: CGFloat = 8
        let isDark = NSAppearance.currentDrawing().isDarkAppearance
        let light = isDark ? NSColor(white: 0.28, alpha: 1) : NSColor(white: 1.0, alpha: 1)
        let dark = isDark ? NSColor(white: 0.21, alpha: 1) : NSColor(white: 0.87, alpha: 1)

        light.setFill()
        context.fill(rect)
        dark.setFill()
        // Anchored to the view, not the image, so panning does not make it crawl.
        var row = 0
        var y = rect.minY - rect.minY.truncatingRemainder(dividingBy: square * 2)
        while y < rect.maxY {
            var x = rect.minX - rect.minX.truncatingRemainder(dividingBy: square * 2)
            if row % 2 == 1 { x += square }
            while x < rect.maxX {
                context.fill(CGRect(x: x, y: y, width: square, height: square))
                x += square * 2
            }
            y += square
            row += 1
        }
    }
}

extension NSAppearance {
    var isDarkAppearance: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
