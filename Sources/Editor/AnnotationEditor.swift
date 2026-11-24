import AppKit

/// Annotation editor for one capture, run in its own short-lived process (see
/// `EditorProcessDelegate`). Like a pin, the window is nothing but the image; the tools
/// float in a Liquid Glass bar just below it (`EditorToolBar`).
final class AnnotationEditor: NSObject, NSWindowDelegate {
    var onPin: ((CapturedImage) -> Void)?
    var onClose: ((AnnotationEditor) -> Void)?

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
    private let toolBar = EditorToolBar()
    /// The size of the picture on screen, changed by a crop.
    private var canvasWidth: NSLayoutConstraint?
    private var canvasHeight: NSLayoutConstraint?
    /// How wide the move handle and the tool bar are together: the window is never narrower.
    private var barRowWidth: CGFloat = 0
    /// The tool bar's view, measured again when a button appears or goes.
    private var barView: NSView?
    /// While a screenshot is being added: the editor is out of the way meanwhile.
    private var adding = false

    /// Edits `capture`, or with `parts` the pictures it was combined from, each where it lies.
    init(capture: CapturedImage, parts: [(picture: CapturedImage, frame: CGRect)] = []) {
        self.capture = capture
        let pictures = parts.isEmpty ? [capture] : parts.map(\.picture)
        let frames = parts.isEmpty ? [CGRect(origin: .zero, size: capture.pointSize)] : parts.map(\.frame)
        let size = Self.canvasSize(for: LayerStack(frames: frames).bounds.size, on: NSScreen.underPointer)
        canvas = AnnotationCanvas(pictures: pictures, frames: frames, background: Settings.combinedBackground,
                                  size: size, color: toolBar.color)
        toolBar.showBackground(canvas.background)
        toolBar.showSeveral(canvas.stack.isSeveral)
        window = EditorWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()

        window.title = L("action.annotate")
        window.setAccessibilityIdentifier("editor")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.onEscape = { [weak self] in
            guard let self = self else { return }
            if self.canvas.isCropping { self.canvas.cancelCrop() } else { self.window.close() }
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.shortcuts = [
            "z": { [weak self] in self?.canvas.undo() },
            "c": { [weak self] in self?.copyResult() },
            "s": { [weak self] in self?.saveResult() },
            "w": { [weak self] in self?.window.close() },
            "=": { [weak self] in self?.zoom(to: EditorZoom.stepIn(from: self?.scroll.magnification ?? 1)) },
            "-": { [weak self] in self?.zoom(to: EditorZoom.stepOut(from: self?.scroll.magnification ?? 1)) },
            "0": { [weak self] in self?.zoom(to: 1) }
        ]
        connectToolBar()
        buildContent(canvasSize: size)
    }

    /// How large a picture of `size` points shows: its own size, shrunk only if it would
    /// not fit on `screen` together with the frame and the tool bar.
    private static func canvasSize(for size: CGSize, on screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let chrome = barHeight + gap + framePadding * 2
        let fit = min(1, visible.width * 0.85 / size.width, (visible.height * 0.9 - chrome) / size.height)
        return NSSize(width: max(24, (size.width * fit).rounded()), height: max(24, (size.height * fit).rounded()))
    }

    func show() {
        // On the screen the pointer is on, where the capture was just looked at.
        if let visible = NSScreen.underPointer?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.minY + (visible.height - window.frame.height) * 2 / 3))
        } else {
            window.center()
        }
        bringBack()
    }

    private func bringBack() {
        QuietMode.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// Takes a screenshot as the app does (`ScreenshotTool`), with the editor out of the
    /// way meanwhile, and puts it beside what is there; Esc leaves everything as it was.
    private func addScreenshot() {
        guard !adding else { return }
        adding = true
        canvas.commitText()
        canvas.commitCrop()
        window.orderOut(nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppInfo.name)-add-\(UUID().uuidString).png")
        ScreenshotTool.run(["-i", "-x"], to: file, windowShadow: true, hidingDesktopIcons: true, failed: { [weak self] _ in
            self?.adding = false
            self?.bringBack()
            NSSound.beep()
        }) { [weak self] _, file in
            // Read once into memory, like the other pictures, and the file deleted.
            let picture = (try? Data(contentsOf: file)).flatMap(CapturedImage.init(data:))
            try? FileManager.default.removeItem(at: file)
            guard let self = self else { return }
            self.adding = false
            self.bringBack()
            if let picture = picture { self.canvas.add(picture) }
        }
    }

    /// What the tool bar's buttons do, and the tool bar following the canvas.
    private func connectToolBar() {
        toolBar.onUndo = { [weak self] in self?.canvas.undo() }
        toolBar.onColor = { [weak self] color in self?.canvas.applyColor(color) }
        toolBar.onTool = { [weak self] tool in
            self?.canvas.commitText()
            // Choosing a tool while cropping keeps the crop, as Return does.
            self?.canvas.commitCrop()
            self?.canvas.tool = tool
        }
        // The crop button begins cropping, and pressed again gives it up, as Esc does.
        toolBar.onCrop = { [weak self] in
            guard let canvas = self?.canvas else { return }
            if canvas.isCropping { canvas.cancelCrop() } else { canvas.beginCrop() }
        }
        canvas.onCroppingChange = { [weak self] cropping in
            guard let self = self else { return }
            self.toolBar.showCropping(cropping, tool: self.canvas.tool)
        }
        canvas.onAreaChange = { [weak self] previous in
            guard let self = self else { return }
            // A screenshot added, or undone, may bring the background button or take it away.
            self.toolBar.showSeveral(self.canvas.stack.isSeveral)
            self.barView?.layoutSubtreeIfNeeded()
            self.barRowWidth = (self.barView?.fittingSize.width ?? 0) + MoveHandle.diameter + Self.handleGap
            self.fitToArea(from: previous)
        }
        toolBar.onAdd = { [weak self] in self?.addScreenshot() }
        // The background last chosen is also the one several screenshots are next combined on.
        toolBar.onBackground = { [weak self] background, continuing in
            self?.canvas.applyBackground(background, continuing: continuing)
        }
        canvas.onBackgroundChange = { [weak self] background in
            Settings.combinedBackground = background
            self?.toolBar.showBackground(background)
        }
        toolBar.onZoom = { [weak self] in self?.zoomClicked() }
        toolBar.onPin = { [weak self] in self?.pinResult() }
        toolBar.onSave = { [weak self] in self?.saveResult() }
        toolBar.onClose = { [weak self] in self?.window.close() }
        toolBar.onCopy = { [weak self] in self?.copyResult() }
        // Return copies, as the one tinted button does; while cropping it keeps the crop.
        canvas.onReturn = { [weak self] in self?.copyResult() }
        canvas.onToolChange = { [weak self] tool in self?.toolBar.show(tool) }
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
        let bar = toolBar.makeView(height: Self.barHeight)
        barView = bar
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
        let width = scroll.widthAnchor.constraint(equalToConstant: canvasSize.width)
        let height = scroll.heightAnchor.constraint(equalToConstant: canvasSize.height)
        canvasWidth = width
        canvasHeight = height
        NSLayoutConstraint.activate([
            width, height,
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
        barRowWidth = bar.fittingSize.width + MoveHandle.diameter + Self.handleGap
        window.setContentSize(contentSize(canvasSize: canvasSize))
    }

    private func contentSize(canvasSize: NSSize) -> NSSize {
        let pad = Self.framePadding
        return NSSize(width: max(canvasSize.width + pad * 2, barRowWidth),
                      height: canvasSize.height + pad * 2 + Self.gap + Self.barHeight)
    }

    /// After a crop, or undoing one, the window takes the size of what is now shown, and
    /// the middle of it stays where it was on screen; the zoom goes back to 1.
    private func fitToArea(from previous: CGRect) {
        let area = canvas.area
        let oldScale = canvas.bounds.width / previous.width
        let middle = NSPoint(x: (area.midX - previous.minX) * oldScale, y: (area.midY - previous.minY) * oldScale)
        let target = window.convertPoint(toScreen: canvas.convert(middle, to: nil))
        scroll.magnification = 1
        let screen = NSScreen.screens.first { $0.frame.contains(target) } ?? window.screen
        let size = Self.canvasSize(for: area.size, on: screen)
        canvasWidth?.constant = size.width
        canvasHeight?.constant = size.height
        canvas.setFrameSize(size)
        window.setContentSize(contentSize(canvasSize: size))
        window.layoutIfNeeded()
        let shown = window.convertPoint(toScreen: canvas.convert(NSPoint(x: size.width / 2, y: size.height / 2), to: nil))
        var frame = window.frame.offsetBy(dx: target.x - shown.x, dy: target.y - shown.y)
        // Never off the screen, if it can be helped.
        if let visible = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
            frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: true)
        zoomChanged()
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
    func runDemo(thenCopy: Bool, thenEdit: Bool = false, thenCrop: Bool = false, zoom: CGFloat = 1) {
        window.layoutIfNeeded()
        canvas.drawSamples(colors: EditorToolBar.palette, thenEdit: thenEdit, thenCrop: thenCrop)
        if thenCopy { copyResult() }
        if zoom > 1 { self.zoom(to: zoom) }
    }

    /// Development aid: `picture` added as a screenshot taken in the editor would be.
    func runAddDemo(_ picture: CapturedImage) {
        window.layoutIfNeeded()
        canvas.add(picture)
    }

    /// Development aid; see `AnnotationCanvas.arrangeSamples`.
    func runArrangeDemo() {
        window.layoutIfNeeded()
        canvas.arrangeSamples()
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
    private func zoomClicked() {
        let largest = EditorZoom.steps[EditorZoom.steps.count - 1]
        zoom(to: scroll.magnification >= largest - 0.01 ? 1 : EditorZoom.stepIn(from: scroll.magnification))
    }

    @objc private func zoomChanged() {
        toolBar.showZoom(atLargest: scroll.magnification >= EditorZoom.steps[EditorZoom.steps.count - 1] - 0.01)
        // The selection handles are drawn for the zoom they are seen at.
        canvas.needsDisplay = true
    }

    // MARK: Results

    /// The pictures where they lie, with the annotations burned in and cropped, or the
    /// untouched capture if it is one picture and nothing was changed. A crop being
    /// adjusted is kept, as Return would.
    private func exported() -> CapturedImage? {
        canvas.commitText()
        canvas.commitCrop()
        if canvas.annotations.isEmpty, !canvas.isCropped, !canvas.stack.isSeveral { return capture }
        guard let data = AnnotationRenderer.export(pictures: canvas.pictures.pictures, stack: canvas.stack,
                                                   background: canvas.background,
                                                   annotations: canvas.annotations, area: canvas.area),
              let result = CapturedImage(data: data) else {
            NSSound.beep()
            return nil
        }
        return result
    }

    private func copyResult() {
        guard let result = exported() else { return }
        result.copyToPasteboard()
        window.close()
    }

    private func pinResult() {
        guard let result = exported() else { return }
        onPin?(result)
        window.close()
    }

    private func saveResult() {
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
