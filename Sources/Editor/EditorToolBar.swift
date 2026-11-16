import AppKit

/// The editor's floating Liquid Glass tool bar: undo, the colour, the tools, zoom, and
/// the ways out (pin, save, close, copy). It tells the editor what was chosen.
final class EditorToolBar: NSObject {
    /// Quick colour choices: red, yellow, green, blue, black, white.
    static let palette: [CGColor] = [
        CGColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        CGColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        CGColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        CGColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    ]
    /// What assistive apps call the quick colours, in the order of `palette`.
    private static let paletteNames = [L("color.red"), L("color.yellow"), L("color.green"),
                                       L("color.blue"), L("color.black"), L("color.white")]

    var onUndo: (() -> Void)?
    var onColor: ((CGColor) -> Void)?
    /// The tool chosen; nil is the pointer, which selects.
    var onTool: ((AnnotationTool?) -> Void)?
    var onZoom: (() -> Void)?
    var onPin: (() -> Void)?
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?

    /// The colour new annotations get, the first quick colour to begin with.
    private(set) var color = EditorToolBar.palette[0]
    private var zoomButton = NSButton()
    private let colorButton = NSButton()
    private let toolPicker = NSSegmentedControl()
    private var colorMenu: NSMenu?

    /// The bar, `height` high.
    func makeView(height: CGFloat) -> NSView {
        colorButton.isBordered = false
        colorButton.image = Self.swatch(color, diameter: 20)
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
        toolPicker.target = self
        toolPicker.action = #selector(toolChanged)
        // Its segments have no identifiers of their own: they are found by name or position.
        toolPicker.setAccessibilityIdentifier("editor.tools")

        // Copy is the main way out of the editor, so it is the one tinted button.
        let copy = NSButton(title: L("action.copy"), target: self, action: #selector(copyClicked))
        copy.bezelStyle = .glass
        copy.borderShape = .capsule
        copy.bezelColor = .controlAccentColor
        copy.controlSize = .large
        copy.setAccessibilityIdentifier("editor.copy")

        zoomButton = iconButton("plus.magnifyingglass", L("editor.zoom"), "editor.zoom", #selector(zoomClicked))
        // The window has no title bar, so the bar also carries the way to close it.
        let row = DraggableRow(views: [
            iconButton("arrow.uturn.backward", L("action.undo"), "editor.undo", #selector(undoClicked)),
            colorButton,
            separator(), toolPicker, separator(),
            zoomButton,
            iconButton("pin", L("action.pin"), "editor.pin", #selector(pinClicked)),
            iconButton("square.and.arrow.down", L("action.save"), "editor.save", #selector(saveClicked)),
            iconButton("xmark", L("editor.close"), "editor.close", #selector(closeClicked)),
            copy
        ])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        colorButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let glass = NSGlassEffectView()
        glass.cornerRadius = height / 2
        glass.contentView = row
        glass.translatesAutoresizingMaskIntoConstraints = false
        return glass
    }

    /// Shows the tool the canvas switched to by itself (nil: the pointer).
    func show(_ tool: AnnotationTool?) {
        toolPicker.selectedSegment = tool.map { $0.rawValue + 1 } ?? 0
    }

    /// The zoom button zooms in until the last step, and from there back to the whole picture.
    func showZoom(atLargest: Bool) {
        zoomButton.image = Self.symbol(atLargest ? "1.magnifyingglass" : "plus.magnifyingglass", L("editor.zoom"))
    }

    @objc private func toolChanged() { onTool?(AnnotationTool(rawValue: toolPicker.selectedSegment - 1)) }
    @objc private func undoClicked() { onUndo?() }
    @objc private func zoomClicked() { onZoom?() }
    @objc private func pinClicked() { onPin?() }
    @objc private func saveClicked() { onSave?() }
    @objc private func closeClicked() { onClose?() }
    @objc private func copyClicked() { onCopy?() }

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
        panel.color = NSColor(cgColor: color) ?? .systemRed
        panel.setTarget(self)
        panel.setAction(#selector(panelColorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func panelColorChanged(_ sender: NSColorPanel) {
        guard let color = sender.color.usingColorSpace(.sRGB)?.cgColor else { return }
        setColor(color)
    }

    private func setColor(_ newColor: CGColor) {
        color = newColor
        colorButton.image = Self.swatch(newColor, diameter: 20)
        onColor?(newColor)
    }
}
