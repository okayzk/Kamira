import AppKit

/// The drawing surface: shows the capture and turns mouse gestures into annotations.
/// A click on an existing annotation selects it instead of drawing: it can then be
/// dragged, reshaped by its handles, recoloured or deleted; double-clicking text edits it.
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    /// What a drag on empty space draws; nil is the pointer, which only selects.
    var tool: AnnotationTool? {
        didSet { if tool != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    /// Called when the canvas itself changed `tool`: selecting an annotation switches to
    /// the tool that drew it.
    var onToolChange: ((AnnotationTool?) -> Void)?
    /// Colour for new annotations; change it with `applyColor(_:)`.
    private(set) var color: CGColor
    private(set) var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    /// The annotation being dragged out right now.
    private var current: Annotation? { didSet { needsDisplay = true } }
    /// Index into `annotations` of the selected one.
    private var selected: Int? { didSet { needsDisplay = true } }
    private enum Drag {
        case move(from: CGPoint, original: Annotation)
        case handle(Int)
    }
    /// What the mouse is doing to the selected annotation right now.
    private var drag: Drag?
    /// Earlier states of `annotations`, newest last; undo goes back one.
    private var history: [[Annotation]] = []
    /// The annotation whose colour the last change set, so that dragging through the
    /// colour picker is one undo step rather than dozens.
    private var lastRecolored: Int?
    /// True while the text field holds an existing text annotation taken out for editing.
    private var editingExistingText = false
    /// How close, in view points, a click must be to count as on an annotation.
    private static let grabDistance: CGFloat = 6

    private let imageSize: CGSize
    private let baseImage: CGImage?
    private let mosaic: CGImage?
    /// Live editor for the text tool; replaced by a text annotation when committed.
    private var textField: NSTextField?
    private var textAnchor = CGPoint.zero
    /// View points per image point.
    private var scale: CGFloat { bounds.width / imageSize.width }
    /// How far the scroll view around the canvas is zoomed in. Handles and the distance
    /// that counts as a hit are divided by it, so they stay the same size on screen.
    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    init(capture: CapturedImage, size: NSSize, color: CGColor) {
        imageSize = capture.pointSize
        self.color = color
        // Only as many pixels as the canvas can show when zoomed in all the way (never
        // more than the capture has); the export decodes the original itself.
        let backing = NSScreen.underPointer?.backingScaleFactor ?? 2
        let largestZoom = EditorZoom.steps[EditorZoom.steps.count - 1]
        baseImage = capture.downsampled(maxPixel: max(size.width, size.height) * backing * largestZoom)
        mosaic = AnnotationRenderer.mosaicImage(for: capture)
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The window can be dragged by its background, and AppKit counts a view that is not
    // opaque as background: without this, drawing would drag the window along.
    override var mouseDownCanMoveWindow: Bool { false }
    /// Arrow for the pointer, crosshair for the drawing tools.
    private var restingCursor: NSCursor { tool == nil ? .arrow : .crosshair }
    override func resetCursorRects() { addCursorRect(bounds, cursor: restingCursor) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if let baseImage = baseImage {
            context.interpolationQuality = .high
            context.draw(baseImage, in: bounds)
        }
        AnnotationRenderer.draw(annotations + (current.map { [$0] } ?? []), in: context,
                                scale: scale, imageSize: imageSize, mosaic: mosaic)
        if let index = selected { drawSelection(of: annotations[index], in: context) }
    }

    /// Marks the selected annotation: round handles where it can be reshaped, otherwise
    /// a dashed outline. Only on screen, never in the exported picture.
    private func drawSelection(of annotation: Annotation, in context: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        context.setStrokeColor(accent)
        let box = annotation.bounds.applying(CGAffineTransform(scaleX: scale, y: scale))
        let handles = annotation.handles
        // One point on screen, however far the canvas is zoomed in.
        let point = 1 / zoom
        if handles.isEmpty {
            context.setLineWidth(1.5 * point)
            context.setLineDash(phase: 0, lengths: [4 * point, 3 * point])
            context.stroke(box.insetBy(dx: -5 * point, dy: -5 * point))
            context.setLineDash(phase: 0, lengths: [])
            return
        }
        if annotation.tool != .arrow {
            context.setLineWidth(point)
            context.stroke(box)
        }
        context.setLineWidth(1.5 * point)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for handle in handles {
            let dot = CGRect(x: handle.x * scale - 4.5 * point, y: handle.y * scale - 4.5 * point,
                             width: 9 * point, height: 9 * point)
            context.fillEllipse(in: dot)
            context.strokeEllipse(in: dot)
        }
    }

    /// Remembers the present state so that `undo()` can come back to it.
    private func record() {
        history.append(annotations)
        lastRecolored = nil
    }

    /// The topmost annotation under `point` (image points).
    private func annotation(at point: CGPoint) -> Int? {
        annotations.indices.last { annotations[$0].hitTest(point, tolerance: Self.grabDistance / scale / zoom) }
    }

    /// The handle of the selected annotation under `point`.
    private func handle(at point: CGPoint) -> Int? {
        guard let index = selected else { return nil }
        let reach = (Self.grabDistance + 2) / scale / zoom
        return annotations[index].handles.firstIndex { hypot($0.x - point.x, $0.y - point.y) <= reach }
    }

    /// Sets the colour for new annotations and recolours the selected one.
    func applyColor(_ newColor: CGColor) {
        color = newColor
        textField?.textColor = NSColor(cgColor: newColor)
        guard let index = selected else { return }
        if lastRecolored != index {
            record()
            lastRecolored = index
        }
        annotations[index].color = newColor
    }

    private func deleteSelected() {
        guard let index = selected else { return }
        record()
        selected = nil
        annotations.remove(at: index)
        annotations = Annotation.renumberingCounters(annotations)
    }

    // The pointer shows whether a click would grab an annotation or draw.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard textField == nil else { return }
        let point = imagePoint(event)
        (handle(at: point) != nil || annotation(at: point) != nil ? NSCursor.openHand : restingCursor).set()
    }

    // MARK: Drawing gestures

    /// Event location in image points, kept inside the image.
    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width) / scale,
                       y: min(max(point.y, 0), bounds.height) / scale)
    }

    override func mouseDown(with event: NSEvent) {
        let hadText = textField != nil
        commitText()
        let point = imagePoint(event)
        // An existing annotation under the pointer takes the click, whatever the tool.
        if let handle = handle(at: point) {
            record()
            drag = .handle(handle)
            return
        }
        if let index = annotation(at: point) {
            selected = index
            if tool != annotations[index].tool {
                tool = annotations[index].tool
                onToolChange?(tool)
            }
            if event.clickCount == 2, annotations[index].tool == .text {
                editText(at: index)
            } else {
                record()
                drag = .move(from: point, original: annotations[index])
            }
            return
        }
        selected = nil
        guard let tool = tool else { return }
        switch tool {
        case .text:
            // A click that just finished one text does not immediately start another.
            if !hadText { beginText(at: point) }
        case .counter:
            let number = annotations.filter { $0.tool == .counter }.count + 1
            record()
            annotations.append(Annotation(tool: .counter, color: color, points: [point], text: "\(number)"))
        default:
            current = Annotation(tool: tool, color: color, points: [point, point])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(event)
        if let index = selected, let drag = drag {
            switch drag {
            case .handle(let handle):
                annotations[index] = annotations[index].movingHandle(handle, to: point)
            case .move(let from, let original):
                annotations[index] = original.moved(by: CGVector(dx: point.x - from.x, dy: point.y - from.y),
                                                    keepingInside: CGRect(origin: .zero, size: imageSize))
            }
            return
        }
        guard var annotation = current else { return }
        if annotation.tool == .pen { annotation.points.append(point) }
        else { annotation.points[1] = point }
        current = annotation
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = drag {
            self.drag = nil
            // A click that only selected changed nothing, so there is nothing to undo.
            if case .move(_, let original) = drag, let index = selected,
               annotations[index].points == original.points {
                history.removeLast()
            }
            return
        }
        guard let annotation = current else { return }
        current = nil
        // Ignore stray clicks that did not drag out anything visible.
        let extent = annotation.points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard max(extent.width, extent.height) * scale >= 3 else { return }
        record()
        annotations.append(annotation)
        // A new shape shows its handles straight away, ready to be adjusted.
        selected = annotation.handles.isEmpty ? nil : annotations.count - 1
    }

    /// Called when ⌘ with the scroll wheel asks for a zoom of `factor` around a point of the canvas.
    var onZoom: ((_ factor: CGFloat, _ centre: NSPoint) -> Void)?

    // ⌘ with the scroll wheel zooms, for a mouse that cannot pinch; otherwise the wheel
    // moves around the zoomed picture as in any scroll view.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        onZoom?(1 + max(-0.5, min(0.5, event.scrollingDeltaY * 0.02)), convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: window?.close() // Esc
        case 51 where selected != nil, 117 where selected != nil: deleteSelected() // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }

    func undo() {
        if textField != nil {
            discardText()
        } else if let previous = history.popLast() {
            selected = nil
            lastRecolored = nil
            annotations = previous
        }
    }

    /// Development aid: replays one gesture per tool through the real mouse handlers,
    /// so the drawing path can be checked without touching the pointer.
    func drawSamples(colors: [CGColor], thenEdit: Bool = false) {
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            let point = convert(NSPoint(x: x * bounds.width, y: y * bounds.height), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window?.windowNumber ?? 0, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func gesture(_ tool: AnnotationTool, _ colorIndex: Int, _ path: [(CGFloat, CGFloat)]) {
            self.tool = tool
            selected = nil
            applyColor(colors[colorIndex])
            mouseDown(with: event(.leftMouseDown, path[0].0, path[0].1))
            for step in path.dropFirst() { mouseDragged(with: event(.leftMouseDragged, step.0, step.1)) }
            mouseUp(with: event(.leftMouseUp, path.last!.0, path.last!.1))
        }
        gesture(.arrow, 0, [(0.08, 0.9), (0.28, 0.72)])
        gesture(.rectangle, 1, [(0.36, 0.62), (0.6, 0.92)])
        gesture(.ellipse, 2, [(0.66, 0.62), (0.9, 0.92)])
        let wave: [(CGFloat, CGFloat)] = (0...20).map { step in
            let t = CGFloat(step)
            return (0.08 + t * 0.012, 0.55 + 0.05 * sin(t * 0.9))
        }
        gesture(.pen, 3, wave)
        gesture(.highlight, 1, [(0.08, 0.36), (0.42, 0.43)])
        gesture(.counter, 0, [(0.5, 0.4)])
        gesture(.counter, 0, [(0.56, 0.4)])
        gesture(.mosaic, 0, [(0.62, 0.12), (0.92, 0.45)])
        gesture(.text, 3, [(0.08, 0.25)])
        textField?.stringValue = "Hello 标注 123"
        commitText()
        guard thenEdit else { return }
        // Edit what was just drawn: delete the first counter (the second becomes 1), turn
        // the pen stroke blue, pull the arrow's head, then move the rectangle and leave
        // it selected.
        gesture(.arrow, 0, [(0.5, 0.4)])
        deleteSelected()
        gesture(.arrow, 0, [(0.08, 0.55)])
        applyColor(colors[3])
        gesture(.arrow, 0, [(0.18, 0.81)])
        gesture(.arrow, 0, [(0.28, 0.72), (0.3, 0.55)])
        gesture(.arrow, 0, [(0.36, 0.8), (0.4, 0.7)])
    }

    // MARK: Text tool

    /// Takes a text annotation out of the picture and back into the text field.
    private func editText(at index: Int) {
        let annotation = annotations[index]
        record()
        selected = nil
        annotations.remove(at: index)
        beginText(at: annotation.points[0], editing: annotation)
    }

    private func beginText(at point: CGPoint, editing existing: Annotation? = nil) {
        editingExistingText = existing != nil
        let field = NSTextField(string: existing?.text ?? "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .boldSystemFont(ofSize: AnnotationRenderer.fontSize * scale)
        field.textColor = NSColor(cgColor: existing?.color ?? color)
        field.delegate = self
        let height = field.fittingSize.height
        let x = point.x * scale
        // The field's text starts 2 pt in from its frame; line the glyphs up with the click.
        field.frame = NSRect(x: x - 2, y: point.y * scale - height,
                             width: max(40, bounds.width - x), height: height)
        addSubview(field)
        textField = field
        textAnchor = point
        window?.makeFirstResponder(field)
    }

    /// Turns the text being typed into an annotation. Safe to call when nothing is being typed.
    func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        let ink = field.textColor?.cgColor ?? color
        field.removeFromSuperview()
        // Taking an existing text out for editing was already recorded as one step;
        // emptying it deletes it.
        if !text.isEmpty {
            if !editingExistingText { record() }
            annotations.append(Annotation(tool: .text, color: ink, points: [textAnchor], text: text))
        }
        editingExistingText = false
        window?.makeFirstResponder(self)
    }

    private func discardText() {
        guard let field = textField else { return }
        textField = nil
        field.removeFromSuperview()
        // Giving up an edit puts the original text back.
        if editingExistingText, let previous = history.popLast() { annotations = previous }
        editingExistingText = false
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ notification: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        discardText()
        return true
    }
}

/// The round grip left of the tool bar: press and drag it to move the editor window. The
/// image itself cannot be used for that, since dragging on it draws.
private final class MoveHandle: NSView {
    static let diameter: CGFloat = 36

    init(label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = label
        setAccessibilityLabel(label)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
                             accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        icon.contentTintColor = .labelColor
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.diameter / 2
        glass.contentView = icon
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The whole disc is the grip, not the icon inside it.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// The tool bar's row of controls: pressing between the controls drags the window.
private final class DraggableRow: NSStackView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// Window that maps ⌘-shortcuts to editor actions; the app has no main menu to carry them.
private final class EditorWindow: NSWindow {
    var shortcuts: [String: () -> Void] = [:]
    var onEscape: (() -> Void)?

    // Borderless windows refuse keyboard focus unless told otherwise.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, !(firstResponder is NSTextView),
           let key = event.charactersIgnoringModifiers?.lowercased(), let action = shortcuts[key] {
            action()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Annotation editor for one capture, run in its own short-lived process (see
/// `EditorProcessDelegate`). Like a pin, the window is nothing but the image; the tools
/// float in a Liquid Glass bar just below it.
final class AnnotationEditor: NSObject, NSWindowDelegate {
    var onPin: ((CapturedImage) -> Void)?
    var onClose: ((AnnotationEditor) -> Void)?

    /// Quick colour choices: red, yellow, green, blue, black, white.
    private static let palette: [CGColor] = [
        CGColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        CGColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        CGColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        CGColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    ]
    /// Width of the frame that shows around the image.
    private static let framePadding: CGFloat = 8
    /// The corner radius of a plain macOS window.
    private static let frameRadius: CGFloat = 16
    /// Gap between the frame and the tool bar.
    private static let gap: CGFloat = 8
    /// Space between the tool bar and the move handle to its left.
    private static let handleGap: CGFloat = 8
    private static let barHeight: CGFloat = 46

    private let capture: CapturedImage
    private let window: EditorWindow
    private let canvas: AnnotationCanvas
    /// Holds the canvas and zooms into it; as large as the picture, so at a zoom of 1
    /// nothing scrolls.
    private let scroll = NSScrollView()
    private var zoomButton = NSButton()
    private let colorButton = NSButton()
    private let toolPicker = NSSegmentedControl()
    private var colorMenu: NSMenu?

    init(capture: CapturedImage) {
        self.capture = capture
        // Original size, shrunk only if the image would not fit on screen.
        let visible = NSScreen.underPointer?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = Self.barHeight + Self.gap + Self.framePadding * 2
        let fit = min(1, visible.width * 0.85 / capture.pointSize.width,
                      (visible.height * 0.9 - chrome) / capture.pointSize.height)
        let size = NSSize(width: max(24, (capture.pointSize.width * fit).rounded()),
                          height: max(24, (capture.pointSize.height * fit).rounded()))
        canvas = AnnotationCanvas(capture: capture, size: size, color: Self.palette[0])
        window = EditorWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        window.title = L("action.annotate")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.onEscape = { [weak self] in self?.window.close() }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.shortcuts = [
            "z": { [weak self] in self?.undo() },
            "c": { [weak self] in self?.copyResult() },
            "s": { [weak self] in self?.saveResult() },
            "w": { [weak self] in self?.window.close() },
            "=": { [weak self] in self?.zoom(to: EditorZoom.stepIn(from: self?.scroll.magnification ?? 1)) },
            "-": { [weak self] in self?.zoom(to: EditorZoom.stepOut(from: self?.scroll.magnification ?? 1)) },
            "0": { [weak self] in self?.zoom(to: 1) }
        ]
        buildContent(canvasSize: size)
    }

    func show() {
        // On the screen the pointer is on, where the capture was just looked at.
        if let visible = NSScreen.underPointer?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.minY + (visible.height - window.frame.height) * 2 / 3))
        } else {
            window.center()
        }
        QuietMode.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// The image at exactly `canvasSize` on a faint frame slightly larger than itself, and
    /// below it the move handle, a disc of its own, followed by the floating tool bar; the
    /// two are centred together under the picture. The rest of the window is transparent.
    private func buildContent(canvasSize: NSSize) {
        scroll.documentView = canvas
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = EditorZoom.steps[0]
        scroll.maxMagnification = EditorZoom.steps[EditorZoom.steps.count - 1]
        scroll.translatesAutoresizingMaskIntoConstraints = false
        canvas.onZoom = { [weak self] factor, centre in
            guard let self = self else { return }
            self.zoom(to: self.scroll.magnification * factor, around: centre)
        }
        // A pinch changes the zoom without going through `zoom(to:)`.
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        let bar = makeToolBar()
        let handle = MoveHandle(label: L("editor.move"))
        // The frame marks where the editor ends and the screen behind it begins: without
        // it a capture of a window is easily taken for the window itself.
        let frame = makeFrame()
        let pad = Self.framePadding
        let content = NSView()
        content.addSubview(frame)
        content.addSubview(scroll)
        content.addSubview(bar)
        content.addSubview(handle)
        window.contentView = content
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: canvasSize.width),
            scroll.heightAnchor.constraint(equalToConstant: canvasSize.height),
            scroll.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            frame.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: -pad),
            frame.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: pad),
            frame.topAnchor.constraint(equalTo: scroll.topAnchor, constant: -pad),
            frame.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: pad),
            // Centring the bar alone left the handle hanging off its left end, so the row
            // as a whole read as off-centre: the bar moves right by half of what the handle takes.
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor,
                                         constant: (MoveHandle.diameter + Self.handleGap) / 2),
            bar.topAnchor.constraint(equalTo: frame.bottomAnchor, constant: Self.gap),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            handle.trailingAnchor.constraint(equalTo: bar.leadingAnchor, constant: -Self.handleGap),
            handle.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
        ])
        let barRow = bar.fittingSize.width + MoveHandle.diameter + Self.handleGap
        window.setContentSize(NSSize(width: max(canvasSize.width + pad * 2, barRow),
                                     height: canvasSize.height + pad * 2 + Self.gap + Self.barHeight))
    }

    /// Glass like the tool bar, so nearly see-through, with the edge glass has and the
    /// corners of a macOS window. Glass also casts a soft shadow of its own, which below
    /// the picture reached down to the tool bar and read as a panel behind both: the
    /// clipping view cuts it off at the frame.
    private func makeFrame() -> NSView {
        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.frameRadius
        glass.autoresizingMask = [.width, .height]
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Self.frameRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.addSubview(glass)
        clip.translatesAutoresizingMaskIntoConstraints = false
        return clip
    }

    /// Development aid; see `AnnotationCanvas.drawSamples`. `zoom` then looks closer at
    /// the middle of the picture.
    func runDemo(thenCopy: Bool, thenEdit: Bool = false, zoom: CGFloat = 1) {
        window.layoutIfNeeded()
        canvas.drawSamples(colors: Self.palette, thenEdit: thenEdit)
        if thenCopy { copyResult() }
        if zoom > 1 { self.zoom(to: zoom) }
    }

    // MARK: Zoom

    /// Zooms the picture in its place; the window keeps its size, and the part that no
    /// longer fits is reached by scrolling. Without `centre` the middle of what is
    /// showing stays in the middle.
    private func zoom(to magnification: CGFloat, around centre: NSPoint? = nil) {
        canvas.commitText()
        let visible = scroll.documentVisibleRect
        scroll.setMagnification(EditorZoom.clamped(magnification),
                                centeredAt: centre ?? NSPoint(x: visible.midX, y: visible.midY))
        zoomChanged()
    }

    /// The button zooms in until the last step, and from there goes back to the whole picture.
    @objc private func zoomClicked() {
        let largest = EditorZoom.steps[EditorZoom.steps.count - 1]
        zoom(to: scroll.magnification >= largest - 0.01 ? 1 : EditorZoom.stepIn(from: scroll.magnification))
    }

    @objc private func zoomChanged() {
        let atLargest = scroll.magnification >= EditorZoom.steps[EditorZoom.steps.count - 1] - 0.01
        zoomButton.image = Self.symbol(atLargest ? "1.magnifyingglass" : "plus.magnifyingglass", L("editor.zoom"))
        // The selection handles are drawn for the zoom they are seen at.
        canvas.needsDisplay = true
    }

    // MARK: Tool bar

    private func makeToolBar() -> NSView {
        colorButton.isBordered = false
        colorButton.image = Self.swatch(Self.palette[0], diameter: 20)
        colorButton.imagePosition = .imageOnly
        colorButton.toolTip = L("editor.color")
        colorButton.target = self
        colorButton.action = #selector(showColorMenu)

        let tools = AnnotationTool.allCases
        // Segment 0 is the pointer; the drawing tools follow in their own order.
        toolPicker.segmentCount = tools.count + 1
        toolPicker.trackingMode = .selectOne
        toolPicker.setImage(Self.symbol("cursorarrow", L("tool.select")), forSegment: 0)
        toolPicker.setToolTip(L("tool.select"), forSegment: 0)
        toolPicker.setWidth(34, forSegment: 0)
        for (index, tool) in tools.enumerated() {
            toolPicker.setImage(Self.symbol(tool.symbolName, tool.label), forSegment: index + 1)
            toolPicker.setToolTip(tool.label, forSegment: index + 1)
            toolPicker.setWidth(34, forSegment: index + 1)
        }
        toolPicker.selectedSegment = 0
        canvas.onToolChange = { [weak self] tool in
            self?.toolPicker.selectedSegment = tool.map { $0.rawValue + 1 } ?? 0
        }
        toolPicker.target = self
        toolPicker.action = #selector(toolChanged)

        // Copy is the main way out of the editor, so it is the one tinted button.
        let copy = NSButton(title: L("action.copy"), target: self, action: #selector(copyResult))
        copy.bezelStyle = .glass
        copy.borderShape = .capsule
        copy.bezelColor = .controlAccentColor
        copy.controlSize = .large

        zoomButton = iconButton("plus.magnifyingglass", L("editor.zoom"), #selector(zoomClicked))
        // The window has no title bar, so the bar also carries the way to close it.
        let row = DraggableRow(views: [
            iconButton("arrow.uturn.backward", L("action.undo"), #selector(undo)),
            colorButton,
            separator(), toolPicker, separator(),
            zoomButton,
            iconButton("pin", L("action.pin"), #selector(pinResult)),
            iconButton("square.and.arrow.down", L("action.save"), #selector(saveResult)),
            iconButton("xmark", L("editor.close"), #selector(closeEditor)),
            copy
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        colorButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.barHeight / 2
        glass.contentView = row
        glass.translatesAutoresizingMaskIntoConstraints = false
        return glass
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: Self.symbol(symbol, label), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = .separatorColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return line
    }

    private static func symbol(_ name: String, _ label: String) -> NSImage {
        // The Latin drawing of each symbol in every language: the Chinese variant of the
        // text tool's symbol is the two small characters 格式, unreadable at this size.
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage())
            .withLocale(Locale(identifier: "en"))
        return image.withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? image
    }

    /// Filled circle used as a colour choice.
    private static func swatch(_ color: CGColor, diameter: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            (NSColor(cgColor: color) ?? .black).setFill()
            circle.fill()
            NSColor(white: 0.5, alpha: 0.7).setStroke()
            circle.lineWidth = 0.75
            circle.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Colour

    /// The quick colours as a row of swatches without names, then the system colour picker.
    @objc private func showColorMenu() {
        let menu = NSMenu()
        let swatches = NSStackView(views: Self.palette.enumerated().map { index, color in
            let button = NSButton(image: Self.swatch(color, diameter: 22), target: self,
                                  action: #selector(swatchChosen(_:)))
            button.isBordered = false
            button.tag = index
            return button
        })
        swatches.orientation = .horizontal
        swatches.spacing = 8
        swatches.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        swatches.frame = NSRect(origin: .zero, size: swatches.fittingSize)
        let row = NSMenuItem()
        row.view = swatches
        menu.addItem(row)
        menu.addItem(.separator())
        let more = NSMenuItem(title: L("editor.moreColors"), action: #selector(showColorPanel), keyEquivalent: "")
        more.target = self
        menu.addItem(more)
        colorMenu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: -8, y: colorButton.bounds.maxY + 10), in: colorButton)
    }

    @objc private func swatchChosen(_ sender: NSButton) {
        colorMenu?.cancelTracking()
        setColor(Self.palette[sender.tag])
    }

    @objc private func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(cgColor: canvas.color) ?? .systemRed
        panel.setTarget(self)
        panel.setAction(#selector(panelColorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func panelColorChanged(_ sender: NSColorPanel) {
        guard let color = sender.color.usingColorSpace(.sRGB)?.cgColor else { return }
        setColor(color)
    }

    private func setColor(_ color: CGColor) {
        canvas.applyColor(color)
        colorButton.image = Self.swatch(color, diameter: 20)
    }

    // MARK: Actions

    @objc private func toolChanged() {
        canvas.commitText()
        canvas.tool = AnnotationTool(rawValue: toolPicker.selectedSegment - 1)
    }

    @objc private func undo() { canvas.undo() }
    @objc private func closeEditor() { window.close() }

    /// The capture with the annotations burned in, or the untouched capture if there are none.
    private func exported() -> CapturedImage? {
        canvas.commitText()
        if canvas.annotations.isEmpty { return capture }
        guard let data = AnnotationRenderer.export(capture: capture, annotations: canvas.annotations),
              let result = CapturedImage(data: data) else {
            NSSound.beep()
            return nil
        }
        return result
    }

    @objc private func copyResult() {
        guard let result = exported() else { return }
        result.copyToPasteboard()
        window.close()
    }

    @objc private func pinResult() {
        guard let result = exported() else { return }
        onPin?(result)
        window.close()
    }

    @objc private func saveResult() {
        guard let result = exported(), let data = result.pngData() else { return }
        let picker = NSSavePanel()
        picker.allowedContentTypes = [.png]
        picker.nameFieldStringValue = capture.suggestedFileName
        picker.directoryURL = Settings.saveDirectory
        // A borderless window cannot carry a sheet, so the panel stands on its own.
        picker.begin { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.window.close()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.close() }
        // Let the close finish before the owner drops its reference to this editor.
        DispatchQueue.main.async { [self] in onClose?(self) }
    }
}
