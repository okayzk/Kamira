import AppKit

/// Makes `view`, a picture whose buttons show only under the pointer, one element that
/// assistive apps can find and use without the pointer: named `label`, with an action for
/// each of its buttons that does what clicking that button does. Nothing on screen
/// changes, and a hidden button stays hidden.
func exposeAsImage(_ view: NSView, label: String, id: String, buttonsIn container: NSView) {
    view.setAccessibilityElement(true)
    view.setAccessibilityIdentifier(id)
    view.setAccessibilityRole(.image)
    view.setAccessibilityLabel(label)
    func buttons(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { subview -> [NSControl] in
            if let control = subview as? NSControl, control.action != nil { return [control] }
            return buttons(in: subview)
        }
    }
    view.setAccessibilityCustomActions(buttons(in: container).map { control in
        let name = control.accessibilityLabel() ?? (control as? NSButton)?.title ?? ""
        return NSAccessibilityCustomAction(name: name) { [weak control] in
            guard let control = control, let action = control.action else { return false }
            return NSApp.sendAction(action, to: control.target, from: control)
        }
    })
}
