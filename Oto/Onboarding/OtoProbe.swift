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
                (.permissions, 0), (.speech, 0), (.tryIt, 0),
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
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if let window = settings.window, let view = window.contentView {
                capture(view, name: "settings", dir: dir)
            }
            exit(0)
        }
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
