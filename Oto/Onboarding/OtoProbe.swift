//
//  OtoProbe.swift
//  Oto
//
//  TEMPORARY verification hook. Removed before commit.
//
//    OTO_SHOT=<dir>           presents onboarding and captures each chapter.
//    OTO_SETTINGS_SHOT=<dir>  presents Settings (Dictation) and captures it.
//  OTO_APPEARANCE=light|dark forces NSApp.appearance for any of them.
//

#if DEBUG

import AppKit

extension Notification.Name {
    /// Probe-only: ask the settings shell to show a pane, and ask a list pane
    /// to open its first row's details or copy it. Never posted in normal use.
    static let otoProbeSelectPane = Notification.Name("otoProbeSelectPane")
    static let otoProbeSearch = Notification.Name("otoProbeSearch")
    static let otoProbeOpenInfo = Notification.Name("otoProbeOpenInfo")
    static let otoProbeCloseInfo = Notification.Name("otoProbeCloseInfo")
    static let otoProbeCopyFirst = Notification.Name("otoProbeCopyFirst")
    /// Probe-only: open the Dictation recorder popover ("hold" or
    /// "handsFree") so its footer can be captured outside the pane's window.
    static let otoProbeOpenRecorder = Notification.Name("otoProbeOpenRecorder")
    /// Probe-only: drive the recorder's Remove path (same code as ⌫).
    static let otoProbeClearRecorder = Notification.Name("otoProbeClearRecorder")
}

@MainActor
enum OtoProbe {
    /// True when a Settings capture was requested. Launch treats it as a
    /// developer session: onboarding stays out of the frame and the first-run
    /// rule that closes Settings does not fire (persisted state untouched).
    static var settingsCaptureRequested: Bool {
        ProcessInfo.processInfo.environment["OTO_SETTINGS_SHOT"] != nil
    }

    static func forceAppearance() {
        guard let name = ProcessInfo.processInfo.environment["OTO_APPEARANCE"] else { return }
        NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
    }

    /// The probe composites a captured view over this surface, so a forced
    /// appearance has to be honoured here too — `NSApp.effectiveAppearance` can
    /// still report the system's while a probe run is overriding it.
    private static var dark: Bool {
        if let name = ProcessInfo.processInfo.environment["OTO_APPEARANCE"] {
            return name == "dark"
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Chapters

    static func captureIfRequested(onboarding: OnboardingWindowController?) {
        guard let path = ProcessInfo.processInfo.environment["OTO_SHOT"],
              let onboarding
        else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        onboarding.show(activating: true)
        Task {
            try? await Task.sleep(for: .seconds(1.0))
            if let window = NSApp.windows.first(where: { $0.title == "Welcome to Oto" }),
               let view = window.contentView {
                capture(view, name: "welcome", dir: dir)
            }
            let steps: [OnboardingStage.Step] = [.how, .catcher, .intelligence, .dictionary, .handsFree]
            for step in steps {
                OnboardingStage.shared.advance(to: step)
                try? await Task.sleep(for: .seconds(0.9))
                if let window = NSApp.windows.first(where: { $0.title == "Welcome to Oto" }),
                   let view = window.contentView {
                    capture(view, name: "\(step)", dir: dir)
                }
            }
            exit(0)
        }
    }

    static func captureSettingsIfRequested(settings: OtoSettingsWindowController?) {
        guard let path = ProcessInfo.processInfo.environment["OTO_SETTINGS_SHOT"],
              let settings
        else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings.show()
        // The window appears under the pointer; a stray mouse-up would be
        // read by the sidebar table as a click and select a random pane.
        // Screenshots need the pane the walk asked for, so no mouse at all.
        settings.window?.ignoresMouseEvents = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            let panes = (ProcessInfo.processInfo.environment["OTO_SETTINGS_PANES"] ?? "")
                .split(separator: ",")
                .compactMap { SettingsPane(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
            guard !panes.isEmpty else {
                if let window = settings.window, let view = shotView(window) {
                    capture(view, name: "settings", dir: dir)
                }
                exit(0)
            }
            let wantsInfo = ProcessInfo.processInfo.environment["OTO_SETTINGS_INFO"] == "1"
            let wantsCopy = ProcessInfo.processInfo.environment["OTO_SETTINGS_COPY"] == "1"
            // Typed-search layout is only visible with text in the field
            // (the list is replaced by "No results"), so the walk can seed it.
            let search = ProcessInfo.processInfo.environment["OTO_SETTINGS_SEARCH"]
            for pane in panes {
                NotificationCenter.default.post(name: .otoProbeSelectPane, object: pane.rawValue)
                try? await Task.sleep(for: .seconds(0.9))
                if let search {
                    NotificationCenter.default.post(name: .otoProbeSearch, object: search)
                    try? await Task.sleep(for: .seconds(0.5))
                }
                guard let window = settings.window, let view = shotView(window) else { continue }
                capture(view, name: "settings-\(pane.rawValue)", dir: dir)
                if let slot = ProcessInfo.processInfo.environment["OTO_SETTINGS_RECORDER"] {
                    // The recorder lives in its own popover window, so the
                    // pane's cached view can never contain it.
                    NotificationCenter.default.post(name: .otoProbeOpenRecorder, object: slot)
                    try? await Task.sleep(for: .seconds(1.0))
                    for window in NSApp.windows where window.isVisible && window !== settings.window {
                        guard let popoverView = window.contentView else { continue }
                        capture(popoverView, name: "settings-\(pane.rawValue)-recorder", dir: dir)
                    }
                    for window in NSApp.windows where window.isVisible {
                        print("probe window \(type(of: window)) frame=\(window.frame)")
                    }
                    if ProcessInfo.processInfo.environment["OTO_SETTINGS_RECORDER_CLEAR"] == "1" {
                        NotificationCenter.default.post(name: .otoProbeClearRecorder, object: slot)
                        try? await Task.sleep(for: .seconds(0.7))
                        for window in NSApp.windows where window.isVisible && window !== settings.window {
                            guard let popoverView = window.contentView else { continue }
                            capture(popoverView, name: "settings-\(pane.rawValue)-recorder-cleared", dir: dir)
                        }
                        capture(view, name: "settings-\(pane.rawValue)-after-clear", dir: dir)
                    }
                }
                if wantsInfo {
                    NotificationCenter.default.post(name: .otoProbeOpenInfo, object: nil)
                    try? await Task.sleep(for: .seconds(0.7))
                    // A SwiftUI popover lives in its own window, so it is
                    // not part of the theme-frame capture. Print the frames
                    // to check the arrow lands on the row's eye button.
                    for window in NSApp.windows where window.isVisible {
                        print("probe window \(type(of: window)) frame=\(window.frame)")
                    }
                    capture(view, name: "settings-\(pane.rawValue)-info", dir: dir)
                    NotificationCenter.default.post(name: .otoProbeCloseInfo, object: nil)
                    try? await Task.sleep(for: .seconds(0.4))
                }
                if wantsCopy {
                    NotificationCenter.default.post(name: .otoProbeCopyFirst, object: nil)
                    try? await Task.sleep(for: .seconds(0.3))
                    capture(view, name: "settings-\(pane.rawValue)-copied", dir: dir)
                }
            }
            // OTO_SETTINGS_HOLD=1 keeps the window on screen for an external
            // screencapture (vibrancy and toolbar glass only render live).
            if ProcessInfo.processInfo.environment["OTO_SETTINGS_HOLD"] == "1" { return }
            exit(0)
        }
    }

    /// `OTO_SETTINGS_FRAME=1` captures the theme frame (titlebar included)
    /// instead of the content view, so a toolbar accessory can be checked
    /// against back/forward. Off by default: content-only shots stay
    /// comparable with the existing probe library.
    private static func shotView(_ window: NSWindow) -> NSView? {
        if ProcessInfo.processInfo.environment["OTO_SETTINGS_FRAME"] == "1" {
            return window.contentView?.superview ?? window.contentView
        }
        return window.contentView
    }

    private static func capture(_ view: NSView, name: String, dir: URL) {
        view.layoutSubtreeIfNeeded()
        guard let content = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("probe: no rep for \(name)\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: content)
        let level: CGFloat = self.dark ? 0 : 1
        let color = NSColor(srgbRed: level, green: level, blue: level, alpha: 1)
        let size = NSSize(width: content.pixelsWide, height: content.pixelsHigh)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            content.draw(in: rect)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("probe: no png for \(name)\n".utf8))
            return
        }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    enum ProbeError: Error { case noDevice, noTexture, noCommand, noImage }
}

#endif
