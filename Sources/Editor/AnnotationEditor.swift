import AppKit

/// Annotation editor for one capture, run in its own short-lived process (see
/// `EditorProcessDelegate`). Like a pin, the window is nothing but the image; the tools
/// float in a Liquid Glass bar just below it.
final class AnnotationEditor: NSObject, NSWindowDelegate {
    var onPin: ((CapturedImage) -> Void)?
    var onClose: ((AnnotationEditor) -> Void)?

    /// Quick colour choices: red, yellow, green, blue, black, white.
    /// What assistive apps call the quick colours, in the order of `palette`.
    private static let paletteNames = [L("color.red"), L("color.yellow"), L("color.green"),
                                       L("color.blue"), L("color.black"), L("color.white")]
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
        window.setAccessibilityIdentifier("editor")
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
        colorButton.setAccessibilityLabel(L("editor.color"))
        colorButton.setAccessibilityIdentifier("editor.color")
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
        // Its segments have no identifiers of their own: they are found by name or position.
        toolPicker.setAccessibilityIdentifier("editor.tools")

        // Copy is the main way out of the editor, so it is the one tinted button.
        let copy = NSButton(title: L("action.copy"), target: self, action: #selector(copyResult))
        copy.bezelStyle = .glass
        copy.borderShape = .capsule
        copy.bezelColor = .controlAccentColor
        copy.controlSize = .large
        copy.setAccessibilityIdentifier("editor.copy")

        zoomButton = iconButton("plus.magnifyingglass", L("editor.zoom"), "editor.zoom", #selector(zoomClicked))
        // The window has no title bar, so the bar also carries the way to close it.
        let row = DraggableRow(views: [
            iconButton("arrow.uturn.backward", L("action.undo"), "editor.undo", #selector(undo)),
            colorButton,
            separator(), toolPicker, separator(),
            zoomButton,
            iconButton("pin", L("action.pin"), "editor.pin", #selector(pinResult)),
            iconButton("square.and.arrow.down", L("action.save"), "editor.save", #selector(saveResult)),
            iconButton("xmark", L("editor.close"), "editor.close", #selector(closeEditor)),
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

    private func iconButton(_ symbol: String, _ label: String, _ id: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: Self.symbol(symbol, label), target: self, action: action)
        button.setAccessibilityIdentifier(id)
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
            button.setAccessibilityLabel(Self.paletteNames[index])
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
