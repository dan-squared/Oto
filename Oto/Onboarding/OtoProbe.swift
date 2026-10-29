//
//  OtoProbe.swift
//  Oto
//
//  TEMPORARY verification hook. Removed before commit.
//
//    OTO_SHADER_SHOT=<dir>    renders the intro offscreen in both polarities.
//    OTO_SHOT=<dir>           presents onboarding and captures each chapter.
//    OTO_SETTINGS_SHOT=<dir>  presents Settings (Dictation) and captures it.
//  OTO_APPEARANCE=light|dark forces NSApp.appearance for any of them.
//

import AppKit
import Metal

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
    static func forceAppearance() {
        guard let name = ProcessInfo.processInfo.environment["OTO_APPEARANCE"] else { return }
        NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
    }

    private static var dark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Shader

    static func runShaderProbeIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["OTO_SHADER_SHOT"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try renderShots(into: dir)
        } catch {
            FileHandle.standardError.write(Data("shader probe failed: \(error)\n".utf8))
        }
        exit(0)
    }

    private static func renderShots(into dir: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ProbeError.noDevice }
        let renderer = try MetalRenderer(device: device)
        let width = 868, height = 608
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue()
        else { throw ProbeError.noTexture }

        for isDark in [true, false] {
            for time in [0.6, 1.2, 1.8, 2.2, 2.6, 3.0] as [Float] {
                renderer.state = ShaderState(
                    elapsed: time, inset: 0, nativeSurface: false, variant: 0,
                    targetSize: CGSize(width: width, height: height),
                    targetOffset: .zero, rayLogoRect: .zero, rayLogoExit: 0,
                    darkAppearance: isDark
                )
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[0].storeAction = .store
                guard let command = queue.makeCommandBuffer() else { throw ProbeError.noCommand }
                try renderer.encode(pass: pass, command: command, width: width, height: height, scale: 1)
                command.commit()
                command.waitUntilCompleted()

                var bgra = [UInt8](repeating: 0, count: width * height * 4)
                bgra.withUnsafeMutableBytes {
                    target.getBytes(
                        $0.baseAddress!, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
                    )
                }
                let surface = OtoSurface.uniforms(dark: isDark)
                let name = "intro-\(isDark ? "dark" : "light")-\(String(format: "%.1f", time)).png"
                try write(bgra: bgra, width: width, height: height, over: surface, to: dir.appendingPathComponent(name))
            }
        }
    }

    private static func write(
        bgra: [UInt8], width: Int, height: Int, over surface: SIMD4<Float>, to url: URL
    ) throws {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            let a = Float(bgra[i + 3]) / 255
            let r = Float(bgra[i + 2]) / 255 + surface.x * (1 - a)
            let g = Float(bgra[i + 1]) / 255 + surface.y * (1 - a)
            let b = Float(bgra[i]) / 255 + surface.z * (1 - a)
            rgba[i] = UInt8(min(1, max(0, r)) * 255)
            rgba[i + 1] = UInt8(min(1, max(0, g)) * 255)
            rgba[i + 2] = UInt8(min(1, max(0, b)) * 255)
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ), let data = rep.bitmapData else { throw ProbeError.noImage }
        rgba.withUnsafeBufferPointer { source in
            data.update(from: source.baseAddress!, count: rgba.count)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ProbeError.noImage }
        try png.write(to: url)
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
            onboarding.finishAnimation()
            try? await Task.sleep(for: .seconds(1.2))
            let steps: [(OnboardingStage.Step, Int)] = [
                (.how, 0), (.how, 1), (.catcher, 0), (.shortcut, 0),
                (.permissions, 0), (.tryIt, 0),
            ]
            for (step, row) in steps {
                OnboardingStage.shared.advance(to: step, row: row)
                try? await Task.sleep(for: .seconds(0.9))
                if let window = NSApp.windows.first(where: { $0.title == "Welcome to Oto" }),
                   let view = window.contentView {
                    capture(view, name: "\(step)-\(row)", dir: dir)
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
        let surface = OtoSurface.uniforms(dark: dark)
        let size = NSSize(width: content.pixelsWide, height: content.pixelsHigh)
        let color = NSColor(
            srgbRed: CGFloat(surface.x), green: CGFloat(surface.y), blue: CGFloat(surface.z), alpha: 1
        )
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
