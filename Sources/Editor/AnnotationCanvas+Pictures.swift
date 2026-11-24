import AppKit

// The canvas with several pictures (screenshots combined into one, or added in the
// editor): each picture's menu, what assistive apps can do with the pictures in place of
// dragging them, adding one, and a demo.
// Picking a picture up and dragging it is in the mouse handlers of `AnnotationCanvas`.
extension AnnotationCanvas {
    /// How far one Move action of an assistive app takes a picture, in points.
    private static let accessibleStep: CGFloat = 10

    /// A picture's own menu, while there are several: bring it to the front or send it to
    /// the back, where they lie over one another.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isCropping, !isTyping, let index = layer(at: imagePoint(event)) else { return nil }
        selected = nil
        selectedLayer = index
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, id, action, enabled) in [
            (L("layer.bringToFront"), "layer.bringToFront", #selector(bringToFront), index < stack.layers.count - 1),
            (L("layer.sendToBack"), "layer.sendToBack", #selector(sendToBack), index > 0)
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.setAccessibilityIdentifier(id)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func bringToFront() {
        guard let index = selectedLayer else { return }
        record()
        stack.bringToFront(index)
        selectedLayer = stack.layers.count - 1
    }

    @objc private func sendToBack() {
        guard let index = selectedLayer else { return }
        record()
        stack.sendToBack(index)
        selectedLayer = 0
    }

    // MARK: Accessibility

    /// Each picture as a picture of its own, named by the order it was taken in, with
    /// actions to restack it and to move it a step at a time.
    override func accessibilityChildren() -> [Any]? {
        let own = super.accessibilityChildren() ?? []
        guard stack.isSeveral, !isCropping else { return own }
        let toView = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -area.minX, y: -area.minY)
        // Bottom to top, as they lie; frames in the canvas's own points.
        let elements = stack.layers.map { layer -> NSAccessibilityElement in
            let element = pictureElements[layer.picture] ?? makePictureElement(layer.picture)
            pictureElements[layer.picture] = element
            element.setAccessibilityFrameInParentSpace(layer.shownFrame.applying(toView).intersection(bounds))
            return element
        }
        return own + elements
    }

    private func makePictureElement(_ picture: Int) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.image)
        element.setAccessibilityLabel(L("layer.name", picture + 1))
        element.setAccessibilityIdentifier("editor.picture")
        element.setAccessibilityParent(self)
        let step = Self.accessibleStep
        let actions: [(String, () -> Void)] = [
            (L("layer.bringToFront"), { [weak self] in self?.restack(picture, toFront: true) }),
            (L("layer.sendToBack"), { [weak self] in self?.restack(picture, toFront: false) }),
            (L("layer.moveLeft"), { [weak self] in self?.move(picture, by: CGVector(dx: -step, dy: 0)) }),
            (L("layer.moveRight"), { [weak self] in self?.move(picture, by: CGVector(dx: step, dy: 0)) }),
            (L("layer.moveUp"), { [weak self] in self?.move(picture, by: CGVector(dx: 0, dy: step)) }),
            (L("layer.moveDown"), { [weak self] in self?.move(picture, by: CGVector(dx: 0, dy: -step)) })
        ]
        element.setAccessibilityCustomActions(actions.map { name, act in
            NSAccessibilityCustomAction(name: name) { act(); return true }
        })
        return element
    }

    // MARK: Adding a screenshot

    /// Puts a screenshot taken in the editor beside what shows (`LayerStack.placeForNext`),
    /// on top and selected. A crop is first made part of the pictures, so that nothing
    /// cut away comes back as the whole grows. One undo step takes it all back.
    func add(_ picture: CapturedImage) {
        commitText()
        commitCrop()
        record()
        let old = area
        if let kept = crop {
            stack.keepOnly(kept)
            annotations = annotations.map { $0.keepingOnly(kept) }
            crop = nil
        }
        let id = pictures.add(picture)
        stack.add(picture: id, at: stack.placeForNext(picture.pointSize), size: picture.pointSize)
        selected = nil
        selectedLayer = stack.layers.count - 1
        onAreaChange?(old)
    }

    private func index(of picture: Int) -> Int? { stack.layers.firstIndex { $0.picture == picture } }

    private func restack(_ picture: Int, toFront: Bool) {
        guard let index = index(of: picture) else { return }
        selectedLayer = index
        if toFront { bringToFront() } else { sendToBack() }
    }

    /// Moves a picture as a drag would, one undo step, the whole taking it in.
    private func move(_ picture: Int, by offset: CGVector) {
        guard let index = index(of: picture), !isCropping else { return }
        record()
        let old = area
        let frame = stack.layers[index].frame
        stack.move(index, to: CGPoint(x: frame.minX + offset.dx, y: frame.minY + offset.dy))
        selectedLayer = index
        if area != old { onAreaChange?(old) }
    }

    // MARK: Demo

    /// Development aid: with the pointer, drags the first picture partly over the second
    /// and below it, past the edge, through the real mouse handlers; brings it to the
    /// front, leaves it selected and puts white between the pictures.
    func arrangeSamples() {
        guard stack.isSeveral else { return }
        tool = nil
        onToolChange?(nil)
        let from = stack.layers[0].frame, onto = stack.layers[1].frame
        let start = CGPoint(x: from.midX, y: from.midY)
        let end = CGPoint(x: onto.minX + 20, y: onto.minY - from.height / 3)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            let inView = NSPoint(x: (point.x - area.minX) * scale, y: (point.y - area.minY) * scale)
            return NSEvent.mouseEvent(with: type, location: convert(inView, to: nil), modifierFlags: [], timestamp: 0,
                                      windowNumber: window?.windowNumber ?? 0, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        mouseDown(with: event(.leftMouseDown, start))
        mouseDragged(with: event(.leftMouseDragged, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)))
        mouseDragged(with: event(.leftMouseDragged, end))
        mouseUp(with: event(.leftMouseUp, end))
        bringToFront()
        applyBackground(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    }
}
