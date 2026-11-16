import UniformTypeIdentifiers

enum AnnotationTool: Int, CaseIterable {
    case arrow, line, rectangle, ellipse, pen, highlight, text, counter, mosaic

    var label: String {
        switch self {
        case .arrow: return L("tool.arrow")
        case .line: return L("tool.line")
        case .rectangle: return L("tool.rectangle")
        case .ellipse: return L("tool.ellipse")
        case .pen: return L("tool.pen")
        case .highlight: return L("tool.highlight")
        case .text: return L("tool.text")
        case .counter: return L("tool.counter")
        case .mosaic: return L("tool.mosaic")
        }
    }

    var symbolName: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .mosaic: return "checkerboard.rectangle"
        }
    }
}
