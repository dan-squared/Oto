//
//  OtoIcon.swift
//  Oto
//
//  Every icon in the app, in one place. Bodies are HugeIcons Stroke Rounded
//  path data (see OtoIconData.swift — MIT, version pinned there), parsed
//  with the same absolute-command approach as the reference Logomark parser
//  (the free set uses only M/L/H/V/C/Z, verified at extraction).
//
//  Rendered as one combined path stroked 1.5pt on the 24-grid, scaled —
//  never filled, round caps/joins, like the source set. To swap styles,
//  regenerate OtoIconData; nothing else changes.
//

import SwiftUI

/// Icon identity. Raw values match OtoIconData members by construction
/// (pinned by OtoIconTests — a missing body fails loudly, never blank).
enum OtoIcon: String, CaseIterable, Sendable {
    case xmark
    case trash
    case warning
    case gear
    case waveform
    case mic
    case book
    case clock
    case quote
    case tap
    case check
    case search
    case accessibility
    case archive
    case keyboard
}

/// Absolute-command SVG path parser (M/L/H/V/C/Z). Multi-pair commands
/// consume groups; C consumes sextuples. Unknown commands end parsing —
/// the set is verified closed at extraction, so this is a backstop, not
/// a path for silent truncation (tests parse every icon).
enum OtoIconPath {
    nonisolated static let grid: CGFloat = 24

    nonisolated static func path(for data: String) -> Path {
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero

        func feed(_ c: Character, _ values: [CGFloat]) {
            switch c {
            case "M", "L":
                // An M with trailing pairs linetos them (SVG rule).
                var i = 0
                var move = c == "M"
                while i + 1 < values.count {
                    let point = CGPoint(x: values[i], y: values[i + 1])
                    if move {
                        path.move(to: point)
                        start = point
                        move = false
                    } else {
                        path.addLine(to: point)
                    }
                    current = point
                    i += 2
                }
            case "H":
                for x in values {
                    current.x = x
                    path.addLine(to: current)
                }
            case "V":
                for y in values {
                    current.y = y
                    path.addLine(to: current)
                }
            case "C":
                var i = 0
                while i + 5 < values.count {
                    path.addCurve(
                        to: CGPoint(x: values[i + 4], y: values[i + 5]),
                        control1: CGPoint(x: values[i], y: values[i + 1]),
                        control2: CGPoint(x: values[i + 2], y: values[i + 3])
                    )
                    current = CGPoint(x: values[i + 4], y: values[i + 5])
                    i += 6
                }
            case "Z":
                path.closeSubpath()
                current = start
            default:
                break
            }
        }

        var token = ""
        var pending: Character?
        var values: [CGFloat] = []
        func pushToken() {
            if !token.isEmpty, let v = Double(token) {
                values.append(CGFloat(v))
            }
            token = ""
        }
        for ch in data {
            if "MLHVCZ".contains(ch) {
                pushToken()
                if let pending { feed(pending, values) }
                pending = ch
                values = []
            } else if ch == "," || ch == " " {
                pushToken()
            } else if ch == "-", !token.isEmpty {
                pushToken()
                token = "-"
            } else {
                token.append(ch)
            }
        }
        pushToken()
        if let pending { feed(pending, values) }
        return path
    }

    nonisolated static func path(for element: OtoIconElement) -> Path {
        switch element {
        case .path(let data):
            return path(for: data)
        case .circle(let cx, let cy, let r):
            return Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        }
    }

    /// All elements combined — stroked once so joins render as one mark.
    nonisolated static func path(for icon: OtoIcon) -> Path {
        let bodies: [OtoIconElement] = switch icon {
        case .xmark: OtoIconData.xmark
        case .trash: OtoIconData.trash
        case .warning: OtoIconData.warning
        case .gear: OtoIconData.gear
        case .waveform: OtoIconData.waveform
        case .mic: OtoIconData.mic
        case .book: OtoIconData.book
        case .clock: OtoIconData.clock
        case .quote: OtoIconData.quote
        case .tap: OtoIconData.tap
        case .check: OtoIconData.check
        case .search: OtoIconData.search
        case .accessibility: OtoIconData.accessibility
        case .archive: OtoIconData.archive
        case .keyboard: OtoIconData.keyboard
        }
        return bodies.reduce(into: Path()) { $0.addPath(path(for: $1)) }
    }
}

/// One icon, stroked. Color comes from the caller (`foregroundStyle`).
struct OtoIconView: View {
    let icon: OtoIcon
    var size: CGFloat = 16

    var body: some View {
        OtoIconPath.path(for: icon)
            .stroke(style: StrokeStyle(lineWidth: 1.5 * size / OtoIconPath.grid, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}
