import AppKit

/// The tool bar's row of controls: pressing between the controls drags the window.
final class DraggableRow: NSStackView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
