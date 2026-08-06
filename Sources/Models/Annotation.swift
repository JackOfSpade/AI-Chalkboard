import Foundation
import AppKit

public enum AnnotationKind: Codable {
    case circle(x: Double, y: Double, radius: Double)
    case arrow(x1: Double, y1: Double, x2: Double, y2: Double)
    case box(x: Double, y: Double, width: Double, height: Double)
    case label(x: Double, y: Double, text: String)
    case grid(stepPx: Double)
    case path(points: [[Double]], strokeWidth: Double, isClosed: Bool)
}

public struct Annotation: Identifiable, Codable {
    public let id: String
    public let screenId: String
    public let kind: AnnotationKind
    public let colorHex: String
    public let label: String?
    public let createdAt: Date

    public init(id: String = UUID().uuidString, screenId: String, kind: AnnotationKind, colorHex: String = "#FF0000", label: String? = nil) {
        self.id = id
        self.screenId = screenId
        self.kind = kind
        self.colorHex = colorHex
        self.label = label
        self.createdAt = Date()
    }
}

public struct ColorParser {
    public static func parse(_ colorString: String?) -> NSColor {
        guard let colorString = colorString?.trimmingCharacters(in: .whitespacesAndNewlines), !colorString.isEmpty else {
            return NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9) // Default bright red
        }
        
        let lower = colorString.lowercased()
        switch lower {
        case "red": return NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9)
        case "green": return NSColor(red: 0.2, green: 0.85, blue: 0.3, alpha: 0.9)
        case "blue": return NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 0.9)
        case "yellow": return NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 0.9)
        case "orange": return NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.9)
        case "purple": return NSColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 0.9)
        case "pink": return NSColor(red: 1.0, green: 0.4, blue: 0.7, alpha: 0.9)
        case "cyan": return NSColor(red: 0.0, green: 0.8, blue: 0.9, alpha: 0.9)
        case "white": return NSColor(white: 1.0, alpha: 0.9)
        case "black": return NSColor(white: 0.1, alpha: 0.9)
        default: break
        }
        
        var hex = lower
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        
        var intVal: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&intVal)
        
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (intVal >> 8) * 17, (intVal >> 4 & 0xF) * 17, (intVal & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, intVal >> 16, intVal >> 8 & 0xFF, intVal & 0xFF)
        case 8: // ARGB or RGBA (32-bit) -> assume RGBA
            (r, g, b, a) = (intVal >> 24, intVal >> 16 & 0xFF, intVal >> 8 & 0xFF, intVal & 0xFF)
        default:
            return NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.9)
        }

        return NSColor(
            red: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: CGFloat(a) / 255.0
        )
    }
}
