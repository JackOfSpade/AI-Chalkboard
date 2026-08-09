import CoreGraphics
import Foundation

/// The resolved drawing operations in an SVG path.  This is intentionally a
/// small, Foundation-free representation so callers can inspect a parsed path
/// (and unit tests can assert its geometry) without having to introspect a
/// `CGPath` callback.
enum SVGPathElement: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(control: CGPoint, to: CGPoint)
    case cubic(control1: CGPoint, control2: CGPoint, to: CGPoint)
    case close
}

/// A parsed SVG path, ready for Core Graphics rendering.  Coordinates stay in
/// the caller's coordinate system; the overlay is responsible for its normal
/// backing-pixel-to-point and Y-axis transforms.
struct SVGPathGeometry {
    let elements: [SVGPathElement]
    let path: CGPath
    let bounds: CGRect

    /// A path containing only moveto commands (or only zero-length segments)
    /// is syntactically valid SVG, but produces no overlay pixels.  The MCP
    /// boundary uses this to reject success-shaped invisible annotations.
    var hasDrawableGeometry: Bool {
        var current: CGPoint?
        var subpathStart: CGPoint?
        for element in elements {
            switch element {
            case let .move(point):
                current = point
                subpathStart = point
            case let .line(point):
                if let current, point != current { return true }
                current = point
            case let .quad(control, to: point):
                if let current, control != current || point != current { return true }
                current = point
            case let .cubic(control1, control2, to: point):
                if let current, control1 != current || control2 != current || point != current { return true }
                current = point
            case .close:
                if let current, let subpathStart, current != subpathStart { return true }
                current = subpathStart
            }
        }
        return false
    }
}

enum SVGPathParseError: Error, Equatable, LocalizedError {
    case emptyPath
    case unexpectedCharacter(Character, offset: Int)
    case unsupportedCommand(Character, offset: Int)
    case expectedNumber(offset: Int)
    case invalidNumber(offset: Int)
    case nonFiniteGeometry
    case invalidArcFlag(offset: Int)
    case missingInitialMove(offset: Int)

    var errorDescription: String? {
        switch self {
        case .emptyPath: return "SVG path is empty"
        case let .unexpectedCharacter(character, offset): return "Unexpected character '\(character)' at offset \(offset)"
        case let .unsupportedCommand(command, offset): return "Unsupported SVG path command '\(command)' at offset \(offset)"
        case let .expectedNumber(offset): return "Expected a finite number at offset \(offset)"
        case let .invalidNumber(offset): return "Invalid SVG number at offset \(offset)"
        case .nonFiniteGeometry: return "SVG path arithmetic produced a non-finite coordinate"
        case let .invalidArcFlag(offset): return "Arc flag must be 0 or 1 at offset \(offset)"
        case let .missingInitialMove(offset): return "SVG path must begin with a moveto command (offset \(offset))"
        }
    }
}

/// Parses the SVG 1.1 path command subset used by the overlay.  It accepts
/// absolute and relative M/L/H/V/C/S/Q/T/A/Z operations, including implicit
/// command repetition and compact arc flags, and reduces elliptical arcs to
/// Core Graphics cubic Bézier segments.
enum SVGPathParser {
    /// Renderer-facing entry point. The path remains in SVG/top-left backing
    /// pixel coordinates; callers may apply their normal drawing transform.
    static func parse(_ pathData: String) throws -> CGPath {
        try parseGeometry(pathData).path
    }

    /// Inspection-oriented entry point with resolved operations and bounds.
    /// This is useful for validation diagnostics and deterministic tests.
    static func parseGeometry(_ pathData: String) throws -> SVGPathGeometry {
        var parser = Parser(pathData)
        let elements = try parser.parse()
        guard elements.allSatisfy(areFinite) else {
            throw SVGPathParseError.nonFiniteGeometry
        }
        let path = makeCGPath(from: elements)
        return SVGPathGeometry(elements: elements, path: path, bounds: path.boundingBoxOfPath)
    }

    private static func areFinite(_ element: SVGPathElement) -> Bool {
        func isFinite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
        switch element {
        case let .move(point), let .line(point): return isFinite(point)
        case let .quad(control, to: point): return isFinite(control) && isFinite(point)
        case let .cubic(control1, control2, to: point):
            return isFinite(control1) && isFinite(control2) && isFinite(point)
        case .close: return true
        }
    }

    private static func makeCGPath(from elements: [SVGPathElement]) -> CGPath {
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case let .move(point): path.move(to: point)
            case let .line(point): path.addLine(to: point)
            case let .quad(control, to): path.addQuadCurve(to: to, control: control)
            case let .cubic(control1, control2, to): path.addCurve(to: to, control1: control1, control2: control2)
            case .close: path.closeSubpath()
            }
        }
        return path.copy()!
    }

    private struct Parser {
        private let bytes: [UInt8]
        private var index = 0
        private var elements: [SVGPathElement] = []
        private var current = CGPoint.zero
        private var subpathStart = CGPoint.zero
        private var hasCurrentPoint = false
        private var previousCommand: UInt8?
        private var previousCubicControl: CGPoint?
        private var previousQuadControl: CGPoint?

        init(_ source: String) {
            bytes = Array(source.utf8)
        }

        mutating func parse() throws -> [SVGPathElement] {
            skipSeparators()
            guard !isAtEnd else { throw SVGPathParseError.emptyPath }

            var activeCommand: UInt8?
            while true {
                skipSeparators()
                guard !isAtEnd else { break }

                if isASCIIAlpha(peek) {
                    let commandOffset = index
                    let command = consume()
                    guard isSupported(command) else {
                        throw SVGPathParseError.unsupportedCommand(Character(String(UnicodeScalar(command))), offset: commandOffset)
                    }
                    activeCommand = command
                } else if activeCommand == nil {
                    throw SVGPathParseError.unexpectedCharacter(Character(UnicodeScalar(peek)), offset: index)
                }

                guard let command = activeCommand else { continue }
                try parse(command: command)
                // A closepath has no repeatable numeric payload.  Requiring a
                // new command afterward prevents an accidental "Z 1 2" from
                // being treated as a second close operation.
                if lowercased(command) == 122 { activeCommand = nil }
            }
            return elements
        }

        private mutating func parse(command: UInt8) throws {
            let absolute = command >= 65 && command <= 90
            let lower = lowercased(command)
            if !hasCurrentPoint && lower != 109 {
                throw SVGPathParseError.missingInitialMove(offset: index)
            }

            switch lower {
            case 109: // M/m
                let first = try point(absolute: absolute)
                move(to: first)
                while hasNumberAhead() {
                    line(to: try point(absolute: absolute))
                }

            case 108: // L/l
                try requireSegment(command)
                repeat { line(to: try point(absolute: absolute)) } while hasNumberAhead()

            case 104: // H/h
                try requireSegment(command)
                repeat {
                    let x = try number()
                    line(to: CGPoint(x: absolute ? x : current.x + x, y: current.y))
                } while hasNumberAhead()

            case 118: // V/v
                try requireSegment(command)
                repeat {
                    let y = try number()
                    line(to: CGPoint(x: current.x, y: absolute ? y : current.y + y))
                } while hasNumberAhead()

            case 99: // C/c
                try requireSegment(command)
                repeat {
                    let c1 = try point(absolute: absolute)
                    let c2 = try point(absolute: absolute)
                    let end = try point(absolute: absolute)
                    cubic(control1: c1, control2: c2, to: end)
                } while hasNumberAhead()

            case 115: // S/s
                try requireSegment(command)
                repeat {
                    let c1: CGPoint
                    if previousCommand == 99 || previousCommand == 115, let previousCubicControl {
                        c1 = reflect(previousCubicControl, around: current)
                    } else {
                        c1 = current
                    }
                    let c2 = try point(absolute: absolute)
                    let end = try point(absolute: absolute)
                    cubic(control1: c1, control2: c2, to: end, command: 115)
                } while hasNumberAhead()

            case 113: // Q/q
                try requireSegment(command)
                repeat {
                    let control = try point(absolute: absolute)
                    let end = try point(absolute: absolute)
                    quad(control: control, to: end)
                } while hasNumberAhead()

            case 116: // T/t
                try requireSegment(command)
                repeat {
                    let control: CGPoint
                    if previousCommand == 113 || previousCommand == 116, let previousQuadControl {
                        control = reflect(previousQuadControl, around: current)
                    } else {
                        control = current
                    }
                    quad(control: control, to: try point(absolute: absolute), command: 116)
                } while hasNumberAhead()

            case 97: // A/a
                try requireSegment(command)
                repeat {
                    let rx = try number()
                    let ry = try number()
                    let rotation = try number()
                    let largeArc = try arcFlag()
                    let sweep = try arcFlag()
                    let end = try point(absolute: absolute)
                    try arc(rx: rx, ry: ry, rotationDegrees: rotation, largeArc: largeArc, sweep: sweep, to: end)
                } while hasNumberAhead()

            case 122: // Z/z
                guard hasCurrentPoint else { throw SVGPathParseError.missingInitialMove(offset: index) }
                elements.append(.close)
                current = subpathStart
                previousCommand = 122
                previousCubicControl = nil
                previousQuadControl = nil

            default:
                // `isSupported` makes this unreachable, retained so that a
                // future supported-command edit cannot silently do nothing.
                throw SVGPathParseError.unsupportedCommand(Character(String(UnicodeScalar(command))), offset: index)
            }
        }

        private mutating func move(to point: CGPoint) {
            elements.append(.move(point))
            current = point
            subpathStart = point
            hasCurrentPoint = true
            previousCommand = 109
            previousCubicControl = nil
            previousQuadControl = nil
        }

        private mutating func line(to point: CGPoint) {
            elements.append(.line(point))
            current = point
            previousCommand = 108
            previousCubicControl = nil
            previousQuadControl = nil
        }

        private mutating func cubic(control1: CGPoint, control2: CGPoint, to point: CGPoint, command: UInt8 = 99) {
            elements.append(.cubic(control1: control1, control2: control2, to: point))
            current = point
            previousCommand = command
            previousCubicControl = control2
            previousQuadControl = nil
        }

        private mutating func quad(control: CGPoint, to point: CGPoint, command: UInt8 = 113) {
            elements.append(.quad(control: control, to: point))
            current = point
            previousCommand = command
            previousCubicControl = nil
            previousQuadControl = control
        }

        /// SVG endpoint arc conversion from the W3C implementation notes.
        /// Core Graphics has no endpoint elliptical-arc primitive, so each
        /// quarter-turn (or smaller) is emitted as an exact tangent-matched
        /// cubic Bézier approximation.
        private mutating func arc(rx inputRX: Double, ry inputRY: Double, rotationDegrees: Double,
                                  largeArc: Bool, sweep: Bool, to end: CGPoint) throws {
            guard inputRX.isFinite, inputRY.isFinite, rotationDegrees.isFinite,
                  end.x.isFinite, end.y.isFinite else {
                throw SVGPathParseError.invalidNumber(offset: index)
            }
            // An arc whose endpoints coincide emits no geometry per SVG, but
            // it is still an arc command: subsequent S/T commands must not
            // reflect a control point from the command before this one.
            if current == end {
                previousCommand = 97
                previousCubicControl = nil
                previousQuadControl = nil
                return
            }
            var rx = abs(inputRX)
            var ry = abs(inputRY)
            guard rx > 0, ry > 0 else { line(to: end); return }

            let phi = rotationDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
            let cosPhi = cos(phi)
            let sinPhi = sin(phi)
            let dx = (current.x - end.x) / 2
            let dy = (current.y - end.y) / 2
            let xPrime = cosPhi * dx + sinPhi * dy
            let yPrime = -sinPhi * dx + cosPhi * dy

            guard dx.isFinite, dy.isFinite, xPrime.isFinite, yPrime.isFinite else {
                throw SVGPathParseError.nonFiniteGeometry
            }
            let lambda = (xPrime * xPrime) / (rx * rx) + (yPrime * yPrime) / (ry * ry)
            guard lambda.isFinite else { throw SVGPathParseError.nonFiniteGeometry }
            if lambda > 1 {
                let factor = sqrt(lambda)
                guard factor.isFinite else { throw SVGPathParseError.nonFiniteGeometry }
                rx *= factor
                ry *= factor
            }

            let rx2 = rx * rx
            let ry2 = ry * ry
            let x2 = xPrime * xPrime
            let y2 = yPrime * yPrime
            let denominator = rx2 * y2 + ry2 * x2
            guard rx.isFinite, ry.isFinite, rx2.isFinite, ry2.isFinite,
                  x2.isFinite, y2.isFinite, denominator.isFinite, denominator > 0 else {
                throw SVGPathParseError.nonFiniteGeometry
            }
            let numerator = max(0, rx2 * ry2 - denominator)
            let sign = largeArc == sweep ? -1.0 : 1.0
            let coefficient = sign * sqrt(numerator / denominator)
            guard numerator.isFinite, coefficient.isFinite else {
                throw SVGPathParseError.nonFiniteGeometry
            }
            let centerPrime = CGPoint(x: coefficient * (rx * yPrime / ry),
                                      y: coefficient * (-ry * xPrime / rx))
            let center = CGPoint(
                x: cosPhi * centerPrime.x - sinPhi * centerPrime.y + (current.x + end.x) / 2,
                y: sinPhi * centerPrime.x + cosPhi * centerPrime.y + (current.y + end.y) / 2
            )

            let unitStart = CGPoint(x: (xPrime - centerPrime.x) / rx, y: (yPrime - centerPrime.y) / ry)
            let unitEnd = CGPoint(x: (-xPrime - centerPrime.x) / rx, y: (-yPrime - centerPrime.y) / ry)
            guard centerPrime.x.isFinite, centerPrime.y.isFinite,
                  center.x.isFinite, center.y.isFinite,
                  unitStart.x.isFinite, unitStart.y.isFinite,
                  unitEnd.x.isFinite, unitEnd.y.isFinite else {
                throw SVGPathParseError.nonFiniteGeometry
            }
            let theta = atan2(unitStart.y, unitStart.x)
            var delta = angle(from: unitStart, to: unitEnd)
            if !sweep, delta > 0 { delta -= 2 * .pi }
            if sweep, delta < 0 { delta += 2 * .pi }
            guard theta.isFinite, delta.isFinite else { throw SVGPathParseError.nonFiniteGeometry }

            let count = max(1, Int(ceil(abs(delta) / (.pi / 2))))
            let step = delta / Double(count)
            for segment in 0 ..< count {
                let startAngle = theta + Double(segment) * step
                let endAngle = startAngle + step
                let alpha = (4.0 / 3.0) * tan(step / 4.0)
                let p0 = CGPoint(x: cos(startAngle), y: sin(startAngle))
                let p3 = CGPoint(x: cos(endAngle), y: sin(endAngle))
                let p1 = CGPoint(x: p0.x - alpha * p0.y, y: p0.y + alpha * p0.x)
                let p2 = CGPoint(x: p3.x + alpha * p3.y, y: p3.y - alpha * p3.x)
                let transform: (CGPoint) -> CGPoint = { unit in
                    CGPoint(x: center.x + cosPhi * rx * unit.x - sinPhi * ry * unit.y,
                            y: center.y + sinPhi * rx * unit.x + cosPhi * ry * unit.y)
                }
                let control1 = transform(p1)
                let control2 = transform(p2)
                let destination = segment == count - 1 ? end : transform(p3)
                guard control1.x.isFinite, control1.y.isFinite,
                      control2.x.isFinite, control2.y.isFinite,
                      destination.x.isFinite, destination.y.isFinite else {
                    throw SVGPathParseError.nonFiniteGeometry
                }
                cubic(control1: control1, control2: control2, to: destination, command: 97)
            }
        }

        private func angle(from lhs: CGPoint, to rhs: CGPoint) -> Double {
            atan2(lhs.x * rhs.y - lhs.y * rhs.x, lhs.x * rhs.x + lhs.y * rhs.y)
        }

        private func reflect(_ control: CGPoint, around point: CGPoint) -> CGPoint {
            CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
        }

        private mutating func requireSegment(_ command: UInt8) throws {
            guard hasNumberAhead() else { throw SVGPathParseError.expectedNumber(offset: index) }
        }

        private mutating func point(absolute: Bool) throws -> CGPoint {
            let x = try number()
            let y = try number()
            let point = CGPoint(x: x, y: y)
            return absolute ? point : CGPoint(x: current.x + point.x, y: current.y + point.y)
        }

        private mutating func arcFlag() throws -> Bool {
            skipSeparators()
            let offset = index
            guard !isAtEnd else { throw SVGPathParseError.invalidArcFlag(offset: offset) }
            let byte = consume()
            switch byte {
            case 48: return false
            case 49: return true
            default: throw SVGPathParseError.invalidArcFlag(offset: offset)
            }
        }

        private mutating func number() throws -> Double {
            skipSeparators()
            let start = index
            guard !isAtEnd else { throw SVGPathParseError.expectedNumber(offset: start) }
            if peek == 43 || peek == 45 { index += 1 }
            var hasDigits = false
            while !isAtEnd, isDigit(peek) { index += 1; hasDigits = true }
            if !isAtEnd, peek == 46 {
                index += 1
                while !isAtEnd, isDigit(peek) { index += 1; hasDigits = true }
            }
            guard hasDigits else {
                index = start
                throw SVGPathParseError.expectedNumber(offset: start)
            }
            if !isAtEnd, peek == 69 || peek == 101 {
                index += 1
                if !isAtEnd, peek == 43 || peek == 45 { index += 1 }
                let exponentStart = index
                while !isAtEnd, isDigit(peek) { index += 1 }
                guard index > exponentStart else { throw SVGPathParseError.invalidNumber(offset: start) }
            }
            let text = String(decoding: bytes[start ..< index], as: UTF8.self)
            guard let result = Double(text), result.isFinite else {
                throw SVGPathParseError.invalidNumber(offset: start)
            }
            return result
        }

        private mutating func skipSeparators() {
            while !isAtEnd, peek == 44 || isWhitespace(peek) { index += 1 }
        }

        private mutating func hasNumberAhead() -> Bool {
            skipSeparators()
            guard !isAtEnd else { return false }
            return isDigit(peek) || peek == 43 || peek == 45 || peek == 46
        }

        private var isAtEnd: Bool { index >= bytes.count }
        private var peek: UInt8 { bytes[index] }
        private mutating func consume() -> UInt8 { defer { index += 1 }; return bytes[index] }
        private func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
        private func isWhitespace(_ byte: UInt8) -> Bool { byte == 9 || byte == 10 || byte == 13 || byte == 32 }
        private func isASCIIAlpha(_ byte: UInt8) -> Bool { (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) }
        private func lowercased(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }
        private func isSupported(_ byte: UInt8) -> Bool { "mMlLhHvVcCsSqQtTaAzZ".utf8.contains(byte) }
    }
}
