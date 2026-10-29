//
//  WelcomeLayout.swift
//  Oto
//
//  Where the mark and the name are at any moment of the welcome, from the
//  same clock the shader follows. The mark is drawn by the shader at the
//  rect this returns; the name is a SwiftUI text laid out beside it. Both
//  come from one set of numbers, so they never drift apart.
//

import AppKit

enum WelcomeLayout {
    /// A frozen frame of the choreography: everything the view needs to place
    /// the mark and the name.
    struct Frame {
        /// The shader's mark, in panel coordinates.
        var markRect: CGRect
        /// Where the name rests at this moment (the pair stays centred as it grows).
        var nameCenter: CGPoint
        var nameFontSize: CGFloat
        /// How far the name has come out from behind the mark, 0…1.
        var nameReveal: CGFloat
        /// Horizontal offset from `nameCenter`: negative while the name is still behind the mark.
        var nameSlide: CGFloat
        /// The name is only drawn right of this x (the mark's right edge), fading in over `nameFront`.
        var nameWindowLeft: CGFloat
        var nameFront: CGFloat
        var nameOpacity: Double
    }

    /// The header line the pair rises to, measured from the top.
    static let headerCenterY: CGFloat = 44
    /// Between the pair and what is said under it while it is the hero.
    static let lineSpacing: CGFloat = 22
    /// The pair and its line read as one group, held a little above the middle.
    static let groupRaise: CGFloat = 24
    /// The mark's size once the pair has risen into the header. The mark is
    /// held a little under the pair's own shrink, so the name reads as the
    /// header and the mark sits beside it rather than over it.
    static let headerMarkSide: CGFloat = 30
    /// What the name and the gap beside it shrink to in the header. The mark
    /// has its own header size, so this is not read from it.
    static let headerScale: CGFloat = 40 / OtoLogoTiming.side
    static let gap: CGFloat = 16
    static let nameFontSize: CGFloat = 42
    static let nameTracking: CGFloat = -1.5
    static let nameWeight: NSFont.Weight = .medium
    /// Width of the soft transparent edge at the mark, where letters emerge.
    static let nameFront: CGFloat = 44
    /// The word beside the mark. Measured once, below.
    static let name = "Oto"

    /// How far the pair settles above the middle so that it and `below` points
    /// of content under it are centred together.
    static func lift(for below: CGFloat) -> CGFloat { self.groupRaise + (self.lineSpacing + below) / 2 }

    /// Where that content starts, for a pair lifted this far.
    static func contentTop(in panel: CGSize, lift: CGFloat) -> CGFloat {
        panel.height / 2 - lift + OtoLogoTiming.side / 2 + self.lineSpacing
    }

    /// The mark settles in the centre; the name slides out from behind it to
    /// the right through a soft transparent edge, last letters first, while
    /// the pair stays centred; the pair then settles `lift` points up, on the
    /// clock, and stays the hero of Welcome. `rise` is not on the clock: it is
    /// the step leaving Welcome, 0…1, and takes the pair to the header line,
    /// shrinking — the mark a little more than the name.
    static func frame(at time: Double, in panel: CGSize, lift: CGFloat = 0, rise: CGFloat = 0) -> Frame {
        let reveal = CGFloat(WelcomeTiming.nameProgress(at: time))
        let settle = CGFloat(WelcomeTiming.settleProgress(at: time))
        let scale = 1 + (self.headerScale - 1) * rise
        let markScale = 1 + (self.headerMarkSide / OtoLogoTiming.side - 1) * rise
        let restY = panel.height / 2 - lift * settle
        let centerY = restY + (self.headerCenterY - restY) * rise
        let nameWidth = self.nameWidth * scale
        let markSide = OtoLogoTiming.side * markScale
        let gapWidth = self.gap * scale
        let total = markSide + (gapWidth + nameWidth) * reveal
        let left = panel.width / 2 - total / 2
        let nameLeft = left + markSide + gapWidth
        // Starts entirely behind the mark, its right edge at the mark's right edge.
        let slide = -(nameWidth + gapWidth) * (1 - reveal)
        // The soft edge closes from its full width to the gap as the name
        // comes out, so the last letter still emerges softly and, once out,
        // nothing of the name stays faded.
        let front = (self.nameFront - (self.nameFront - self.gap) * reveal) * scale
        return Frame(
            markRect: CGRect(x: left, y: centerY - markSide / 2, width: markSide, height: markSide),
            nameCenter: CGPoint(x: nameLeft + nameWidth / 2, y: centerY),
            nameFontSize: self.nameFontSize * scale,
            nameReveal: reveal,
            nameSlide: slide,
            nameWindowLeft: left + markSide,
            nameFront: front,
            nameOpacity: 1
        )
    }

    /// The wordmark's own font, so the measured width and the drawn text are
    /// the same object.
    static func font(size: CGFloat) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: self.nameWeight)
        return system.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: size) } ?? system
    }

    // MARK: Private

    /// Measured once with the same font the view draws, so the pair is
    /// centred on the very first frame instead of after a layout pass.
    private static let nameWidth: CGFloat = {
        let text = NSAttributedString(
            string: WelcomeLayout.name,
            attributes: [
                .font: WelcomeLayout.font(size: WelcomeLayout.nameFontSize),
                .kern: WelcomeLayout.nameTracking,
            ]
        )
        return ceil(text.size().width)
    }()
}
