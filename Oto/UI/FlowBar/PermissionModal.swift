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
//  to maxWidth (460). Corners: 16pt card, 8pt button (button measured
//  from the reference at r/height ≈ 0.22; the strict outer − 12 gap
//  would sharpen it to 4, far past the reference).
//

import AppKit

/// Grant-button routing. Pure so the branch is headless-tested without
/// touching TCC: undetermined → the system prompt ("access giving window");
/// anything else → Settings (a prompt would no-op once denied).
enum PermissionGrantAction {
    case systemPrompt
    case openSettings
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

/// The card itself: clear container + one shape layer + label + real button.
/// No self-drawn shadow (window owns depth — pill v5 gotcha); no hosting view
/// (pill v2 frame-bug class — never again).
@MainActor
final class PermissionCardView: NSView {
    /// Hard ceiling: the card grows to fit its words, never past this.
    nonisolated static let maxWidth: CGFloat = 460
    nonisolated static let height: CGFloat = 60
    /// Outer card radius. Reference-matched (less round than the old 24):
    /// the button radius derives from it with an 8pt gap so it lands on
    /// the measured reference ratio (r/height ≈ 0.22 → 8pt on 36pt).
    nonisolated static let cardRadius: CGFloat = 16
    nonisolated static let buttonHeight: CGFloat = 36
    /// Button corner radius = card radius − 8, floored so a future taller
    /// card can never invert the curve.
    nonisolated static var buttonRadius: CGFloat {
        max(4, cardRadius - 8)
    }

    var onGrant: (() -> Void)?

    private let bg = CAShapeLayer()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "Microphone Permission Required")
    private let button = NSButton()
    private(set) var contentSize: NSSize = .zero
    private var didClampTitle = false

    init(onGrant: (() -> Void)?) {
        self.onGrant = onGrant
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(bg)

        icon.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
        icon.contentTintColor = .systemRed
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        addSubview(title)

        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.buttonRadius
        button.target = self
        button.action = #selector(didTapGrant)
        addSubview(button)

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

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(button.frame, cursor: .pointingHand)
    }

    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        bg.fillColor = (dark
            ? NSColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1)
            : NSColor.white).cgColor
        button.layer?.backgroundColor = (dark
            ? NSColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1)
            : NSColor(white: 0.11, alpha: 1)).cgColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        button.attributedTitle = NSAttributedString(string: "Grant Permission", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: dark ? NSColor.black : NSColor.white,
            .paragraphStyle: paragraph,
        ])
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
        let pad: CGFloat = 11
        let iconSide: CGFloat = 18
        let gapIcon: CGFloat = 7
        let gapButton: CGFloat = 9
        let buttonHPad: CGFloat = 15
        let buttonH = Self.buttonHeight
        let h = Self.height

        let typeface = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        let titleW = ceil(Self.textWidth(title.stringValue, font: typeface)) + 4
        let titleH = ceil(Self.textHeight(title.stringValue, font: typeface))
        let buttonW = ceil(Self.textWidth("Grant Permission", font: typeface)) + buttonHPad * 2

        var width = pad + iconSide + gapIcon + titleW + gapButton + buttonW + pad
        var fittedTitleW = titleW
        didClampTitle = false
        if width > Self.maxWidth {
            fittedTitleW = max(0, titleW - (width - Self.maxWidth))
            width = Self.maxWidth
            didClampTitle = fittedTitleW < titleW
        }

        contentSize = NSSize(width: width, height: h)
        setFrameSize(contentSize)
        bg.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: contentSize),
            cornerWidth: Self.cardRadius, cornerHeight: Self.cardRadius, transform: nil
        )

        let midY = h / 2
        icon.frame = CGRect(x: pad, y: midY - iconSide / 2, width: iconSide, height: iconSide)
        // Centered block, not full-height: a full-height label draws its
        // text high while the icon sits at midY — the pair must share a center.
        title.frame = CGRect(
            x: pad + iconSide + gapIcon, y: midY - titleH / 2,
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

    // MARK: - Test hooks (no window needed)

    func titleText() -> String { title.stringValue }
    func contentWidth() -> CGFloat { contentSize.width }
    /// True when the 460 ceiling clipped the title — must stay false.
    func titleClipped() -> Bool { didClampTitle }
    func titleMidY() -> CGFloat { title.frame.midY }
    func iconMidY() -> CGFloat { icon.frame.midY }

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
    nonisolated static let visibleDuration: Double = 5.0

    private var panel: NSPanel?
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
            contentWidth = card.contentSize.width
            panel = FlowBarPanel.makePanel(
                contentView: card,
                size: NSSize(width: contentWidth, height: Self.height)
            )
        }
    }

    func show(displayID: CGDirectDisplayID?, position: FlowBarPosition) {
        prewarm()
        guard let (screen, _) = FlowBarPanel.resolveScreen(displayID: displayID) else { return }
        let frame = FlowBarPosition.frame(
            width: contentWidth, height: Self.height, on: screen.visibleFrame, position: position
        )
        // A fresh show supersedes any pending fade: full 5s, never truncated.
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
