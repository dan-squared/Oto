//
//  PermissionModal.swift
//  Oto
//
//  Mic-denied mini modal: when dictation fails with .microphoneDenied, the
//  pill stays out of the way and this card renders at the pill slot instead
//  (no flash-on-then-melt). One action: "Grant Permission" prompts the
//  system mic dialog when status is notDetermined, otherwise deep-links
//  System Settings at Privacy & Security → Microphone (with fallbacks).
//  Appearance-aware: semantic colors + effectiveAppearance repaint, no
//  in-app toggle. Auto-dismiss: 5s visible, then fades out (no close
//  button, by design).
//
//  Rendered as AppKit/CALayer (PillContentView precedent), NOT SwiftUI
//  hosting: the pill's two frame passes proved this recipe composites
//  cleanly in a transparent panel — layer-backed clear container, card as
//  one CAShapeLayer, depth from the window shadow only. Width is
//  content-fitted (12.5pt type, 18pt icon, string-measured) and clamped
//  to maxWidth (460).
//
//  Since 2026-11-01 it is the PILL EXPANDED, not a banner: a 44pt capsule
//  wearing the pill's own ramp and scrim (PillPalette, so it follows the
//  colour chosen in Settings), with the action as a 30pt pill inside it,
//  and it opens out of the pill's own rect on MorphCurve's 420 ms shape
//  curve. Corners are half the height on both — capsules, never rounded
//  rectangles.
//

import AppKit

/// Grant-button routing. Pure so the branch is headless-tested without
/// touching TCC: undetermined → the system prompt ("access giving window");
/// anything else → Settings (a prompt would no-op once denied).
enum PermissionGrantAction {
    case systemPrompt
    case openSettings
}

/// What the card says for each mic state. macOS presents its own TCC dialog
/// once, and only while the status is undetermined; after a denial the
/// system will never ask again, so this card is the only recovery surface
/// (deep link to System Settings). The words follow that truth: "Allow"
/// before the first answer, "Open Settings" after it. Pure — test-pinned.
struct PermissionCardCopy: Equatable {
    let title: String
    let action: String

    nonisolated static func forStatus(_ status: PermissionsManager.MicrophoneStatus) -> Self {
        switch status {
        case .notDetermined:
            Self(title: "Microphone Permission Required", action: "Allow Microphone")
        case .denied, .granted:
            // Granted is unreachable (the card only shows on a denied
            // capture); it reads as denied rather than promising a prompt.
            Self(title: "Microphone Access Is Off", action: "Open Settings")
        }
    }
}

/// System Settings deep links, most specific first. The Microphone anchor is
/// the long-standing `com.apple.preference.security` pane path; the two
/// fallbacks keep the button useful even if a future macOS renames the pane.
/// Pure builder — the exact strings are test-pinned.
enum MicSettingsLink {
    nonisolated static func candidates() -> [URL] {
        [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:",
        ].compactMap(URL.init(string:))
    }
}

/// Opens the first candidate System Settings URL that the system accepts.
/// One call, no retries: a pane anchor that opens is the right pane.
enum SettingsLinkOpener {
    @MainActor
    static func open(_ candidates: [URL]) {
        for url in candidates {
            if NSWorkspace.shared.open(url) { break }
        }
    }
}

/// The card itself: clear container + one shape layer + label + real button.
/// No self-drawn shadow (window owns depth — pill v5 gotcha); no hosting view
/// (pill v2 frame-bug class — never again).
@MainActor
final class PermissionCardView: NSView {
    /// Hard ceiling: the card grows to fit its words, never past this.
    nonisolated static let maxWidth: CGFloat = 460
    /// The pill, expanded — not a second, bigger surface. 44 pt is a
    /// capsule the pill's own 26.4 pt can grow into without becoming a
    /// banner (the 60 pt v1 card read as a notification, user 2026-11-01).
    nonisolated static let height: CGFloat = 44
    /// Outer radius = half the height: a capsule, exactly like the pill.
    nonisolated static var cardRadius: CGFloat { height / 2 }
    /// The action is a pill inside the pill: 30 pt tall, radius 15.
    nonisolated static let buttonHeight: CGFloat = 30
    nonisolated static var buttonRadius: CGFloat { buttonHeight / 2 }

    var onGrant: (() -> Void)?

    private let bg = CAShapeLayer()
    /// The pill's own ramp, painted over the scrim — same stops, same
    /// horizontal axis, same palette: the card is the pill's finish, not a
    /// lookalike. Masked by `bg`'s capsule so the two silhouettes cannot
    /// disagree.
    private let ramp = CAGradientLayer()
    private let capsule = CAShapeLayer()
    /// The real material, exactly as the pill builds it: frost with the
    /// palette's tint, hosting an ink view that carries the scrim, the ramp
    /// and every subview (AppKit only guarantees the content view sits
    /// inside the glass).
    private let glass = NSGlassEffectView()
    private let ink = NSView()
    private let title = NSTextField(labelWithString: "")
    private let button = NSButton()
    private(set) var contentSize: NSSize = .zero
    private var didClampTitle = false
    private(set) var copy = PermissionCardCopy.forStatus(.notDetermined)

    /// The card's colour is FIXED red, not the pill's choice: this is a
    /// permission failure, and a warning that turns sky blue because of a
    /// cosmetic setting reads as decoration (user, 2026-11-01: "make sure it
    /// is red … it was a mistake to make it similar with the pill colour").
    /// It still wears the pill's *finish* — frost, scrim, five-stop ramp —
    /// in crimson.
    nonisolated static let paletteColor: PillColor = .crimson

    init(onGrant: (() -> Void)?) {
        self.onGrant = onGrant
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // The pill's hierarchy, verbatim: a real glass capsule whose content
        // view carries the scrim, the ramp and every subview.
        ink.wantsLayer = true
        ink.layer?.backgroundColor = NSColor.clear.cgColor
        bg.fillColor = PillPalette(color: Self.paletteColor).scrim
        ink.layer?.addSublayer(bg)
        capsule.fillColor = NSColor.black.cgColor
        ramp.startPoint = CGPoint(x: 0.0, y: 0.5)
        ramp.endPoint = CGPoint(x: 1.0, y: 0.5)
        ramp.mask = capsule
        ink.layer?.addSublayer(ramp)
        glass.style = .regular
        glass.contentView = ink
        addSubview(glass)

        self.title.stringValue = self.copy.title

        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        ink.addSubview(title)

        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.buttonRadius
        button.target = self
        button.action = #selector(didTapGrant)
        ink.addSubview(button)

        applyAppearance()
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PermissionCardView has no nib")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Re-words the card for the live mic status before it is positioned.
    /// One card instance is prewarmed at launch; the words are the only
    /// thing that varies between "ask" and "go fix it".
    func configure(_ copy: PermissionCardCopy) {
        // Repaint every show, not only on re-word: the card carries the
        // pill's colour, and the user can change that between failures.
        if copy != self.copy {
            self.copy = copy
            self.title.stringValue = copy.title
        }
        applyAppearance()
        relayout()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(button.convert(button.bounds, to: self), cursor: .pointingHand)
    }

    private func applyAppearance() {
        let palette = PillPalette(color: Self.paletteColor)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        glass.tintColor = palette.tint
        glass.cornerRadius = Self.cardRadius
        bg.fillColor = palette.scrim
        bg.opacity = reduceTransparency ? 1 : Float(PillChrome.scrimAlpha)
        ramp.colors = palette.bodyColors(opaque: reduceTransparency)
        let pale = PillPalette.mix(
            Self.paletteColor.base, toward: .white,
            by: max(Self.paletteColor.tipDepth, 0.78)
        )
        button.layer?.backgroundColor = pale.cgColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        button.attributedTitle = NSAttributedString(string: self.copy.action, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor(white: 0.08, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        self.title.textColor = .white
    }

    /// Measure the words, fit the card, clamp to maxWidth. Title truncates
    /// only as a fallback that the 12.5pt metrics should never reach
    /// (measured: ~421pt all-in against the 460 ceiling).
    ///
    /// Both widths come from the attributed strings at their exact fonts,
    /// not from NSButton/NSTextField intrinsics: a borderless button's
    /// intrinsic carries bezel padding that varies by machine and pushed
    /// the old math over the ceiling (user saw "Requir…"). The +4 on the
    /// title covers NSTextField cell slop so the tight string measure
    /// never under-sizes the field.
    private func relayout() {
        // No icon: the words and the remedy are the whole message (user,
        // 2026-11-01 — the warning glyph on the left is not needed).
        let pad: CGFloat = 16
        let gapButton: CGFloat = 10
        let buttonHPad: CGFloat = 15
        let buttonH = Self.buttonHeight
        let h = Self.height

        let typeface = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let titleW = ceil(Self.textWidth(self.copy.title, font: typeface)) + 4
        let titleH = ceil(Self.textHeight(self.copy.title, font: typeface))
        let buttonW = ceil(Self.textWidth(self.copy.action, font: typeface)) + buttonHPad * 2

        var width = pad + titleW + gapButton + buttonW + pad
        var fittedTitleW = titleW
        didClampTitle = false
        if width > Self.maxWidth {
            fittedTitleW = max(0, titleW - (width - Self.maxWidth))
            width = Self.maxWidth
            didClampTitle = fittedTitleW < titleW
        }

        contentSize = NSSize(width: width, height: h)
        setFrameSize(contentSize)
        glass.frame = bounds
        glass.cornerRadius = Self.cardRadius
        ink.frame = glass.bounds
        let rect = CGRect(origin: .zero, size: glass.bounds.size)
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: Self.cardRadius, cornerHeight: Self.cardRadius, transform: nil
        )
        bg.path = path
        capsule.path = path
        capsule.frame = rect
        ramp.frame = rect

        let midY = h / 2
        title.frame = CGRect(
            x: pad, y: midY - titleH / 2,
            width: fittedTitleW, height: titleH
        )
        button.frame = CGRect(
            x: width - pad - buttonW, y: midY - buttonH / 2,
            width: buttonW, height: buttonH
        )
        window?.invalidateCursorRects(for: self)
    }

    @objc private func didTapGrant() {
        onGrant?()
    }

    /// Expands out of the pill's own rect. The card is a capsule at every
    /// scale, so a scale transform IS the shape morph — no radius to
    /// interpolate, no window resize (catcher precedent), and the slot edge
    /// stays put while the silhouette opens.
    func morph(from pill: NSRect, card: NSRect, position: FlowBarPosition) {
        guard let layer, card.width > 0, card.height > 0 else { return }
        let sx0 = pill.width / card.width
        let sy0 = pill.height / card.height
        // Anchor on the edge the pill shares with the card: top slot grows
        // downward, bottom slot upward (y-up layer space).
        layer.anchorPoint = CGPoint(x: 0.5, y: position == .top ? 1 : 0)
        layer.position = CGPoint(
            x: bounds.midX, y: position == .top ? bounds.maxY : bounds.minY
        )
        let values = MorphCurve.stops.map { stop -> NSValue in
            let t = CGFloat(stop.value)
            let sx = sx0 + (1 - sx0) * t
            let sy = sy0 + (1 - sy0) * t
            return NSValue(caTransform3D: CATransform3DMakeScale(sx, sy, 1))
        }
        let anim = CAKeyframeAnimation(keyPath: "transform")
        anim.values = values
        anim.keyTimes = MorphCurve.keyTimes
        anim.duration = 0.42
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fillMode = .backwards
        layer.add(anim, forKey: "oto.permission.morph")
        layer.transform = CATransform3DIdentity
    }

    // MARK: - Test hooks (no window needed)

    func titleText() -> String { title.stringValue }
    func contentWidth() -> CGFloat { contentSize.width }
    /// True when the 460 ceiling clipped the title — must stay false.
    func titleClipped() -> Bool { didClampTitle }
    func titleMidY() -> CGFloat { title.frame.midY }

    /// Deterministic string measure at an exact font. Used for layout so
    /// machine-dependent control padding can't change the card width.
    nonisolated static func textSize(_ string: String, font: NSFont) -> NSSize {
        let attr = NSAttributedString(string: string, attributes: [.font: font])
        return attr.boundingRect(
            with: NSSize(width: 10_000, height: 10_000),
            options: [.usesLineFragmentOrigin]
        ).size
    }

    nonisolated static func textWidth(_ string: String, font: NSFont) -> CGFloat {
        textSize(string, font: font).width
    }

    nonisolated static func textHeight(_ string: String, font: NSFont) -> CGFloat {
        textSize(string, font: font).height
    }
}

@Observable @MainActor
final class PermissionModalController {
    nonisolated static let height: CGFloat = PermissionCardView.height
    /// Visible window: long enough to read + reach the button (macOS banner
    /// persistence class), short enough to never linger. Then fades out.
    /// 10 s per explicit product direction (5 s missed too many glances).
    nonisolated static let visibleDuration: Double = 10.0

    private var panel: NSPanel?
    private var card: PermissionCardView?
    private var contentWidth: CGFloat = 0
    private var hideTask: Task<Void, Never>?
    private var showGeneration: UInt64 = 0
    /// Internal for tests: prewarm stability.
    var hasPanel: Bool { panel != nil }

    /// MainActor-bound (MicrophoneStatus's synthesized Equatable inherits
    /// default isolation); all callers — grant() and tests — are MainActor.
    static func action(
        for status: PermissionsManager.MicrophoneStatus
    ) -> PermissionGrantAction {
        status == .notDetermined ? .systemPrompt : .openSettings
    }

    /// Build panel + card once, off the transition path (catcher precedent).
    /// Never orders front — pure construction cost moved to launch.
    func prewarm() {
        if panel == nil {
            let card = PermissionCardView(onGrant: { [weak self] in
                self?.grant()
            })
            self.card = card
            contentWidth = card.contentSize.width
            panel = FlowBarPanel.makePanel(
                contentView: card,
                size: NSSize(width: contentWidth, height: Self.height)
            )
        }
    }

    func show(displayID: CGDirectDisplayID?, position: FlowBarPosition) {
        prewarm()
        // The card's words follow the live status: macOS prompts natively
        // only while undetermined; after a denial this card is the route.
        if let card {
            card.configure(PermissionCardCopy.forStatus(PermissionsManager().microphoneStatus()))
            contentWidth = card.contentSize.width
        }
        guard let (screen, _) = FlowBarPanel.resolveScreen(displayID: displayID) else { return }
        let frame = FlowBarPosition.frame(
            width: contentWidth, height: Self.height, on: screen.visibleFrame, position: position
        )
        // The card opens out of the pill, not on top of it: same slot,
        // same capsule, the reference's 420 ms shape curve.
        let pill = FlowBarPosition.frame(
            width: VisualizerMath.dictationWidth,
            height: VisualizerMath.pillHeight,
            on: screen.visibleFrame,
            position: position
        )
        card?.morph(from: pill, card: frame, position: position)
        // A fresh show supersedes any pending fade: full 10s, never truncated.
        showGeneration += 1
        let generation = showGeneration
        hideTask?.cancel()
        panel?.setFrame(frame, display: false)
        panel?.alphaValue = 0
        // orderFront, never key: focus must stay wherever the user had it.
        panel?.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 1
        }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(Self.visibleDuration))
            guard !Task.isCancelled, generation == self.showGeneration else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panel?.animator().alphaValue = 0
            }, completionHandler: {
                // Late hide() already ordered out: only land when still ours.
                if generation == self.showGeneration {
                    self.panel?.orderOut(nil)
                }
            })
        }
    }

    func hide() {
        // Cancel-before-orderOut: a new show after this starts clean.
        showGeneration += 1
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Test seam: opener injectable so tests never launch Settings.
    func grant(opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        switch Self.action(for: PermissionsManager().microphoneStatus()) {
        case .systemPrompt:
            Task { _ = await PermissionsManager().requestMicrophone() }
        case .openSettings:
            for url in MicSettingsLink.candidates() {
                if opener(url) { break }
            }
        }
    }
}
