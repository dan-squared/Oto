//
//  MetalOnboardingShaderView.swift
//  Oto
//
//  The arrival's light. Ported from Firstlight's Waves shader: the same
//  living field, bloom and condensation into the mark, with Oto's palette
//  (cool silver light gathering into the white waveform bars).
//
//  The shader is compiled into the app's default Metal library by Xcode; the
//  renderer only looks the functions up. A source copy in the bundle is still
//  honoured as a fallback, so a stripped metallib cannot take the intro down.
//

import MetalKit
import SwiftUI

private final class TransparentMetalView: MTKView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        self.updateResolution()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.updateResolution()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.updateResolution()
        self.needsDisplay = true
    }

    private func updateResolution() {
        // Soft light needs less sampling than native text. A 1.5x ceiling keeps
        // the 28-sample volume within a 60 Hz GPU budget on Retina.
        let scale = min(window?.backingScaleFactor ?? 2, 1.5)
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if drawableSize != size { drawableSize = size }
    }
}

struct MetalOnboardingShaderView: NSViewRepresentable {
    final class Coordinator {
        var renderer: MetalRenderer?
    }

    let elapsed: Float
    let inset: Float
    let nativeSurface: Bool
    let variant: Int
    var rayLogoRect: CGRect = .zero
    var rayLogoExit: Float = 0
    var targetSize: CGSize = .zero
    var targetOffset: CGPoint = .zero
    let onFailure: (String) -> Void
    var onPresented: ((Double) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = TransparentMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        // The mark and the SwiftUI name move as one piece: the drawable is
        // presented inside the same Core Animation transaction as the layout,
        // not one display cycle later.
        view.presentsWithTransaction = true
        do {
            guard let device = view.device else { throw ShaderError.unavailable }
            let renderer = try MetalRenderer(device: device)
            renderer.onFailure = self.onFailure
            renderer.onPresented = self.onPresented
            context.coordinator.renderer = renderer
            view.delegate = renderer
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { onFailure(message) }
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.onPresented = self.onPresented
        let state = ShaderState(
            elapsed: elapsed, inset: inset, nativeSurface: nativeSurface, variant: variant,
            targetSize: targetSize, targetOffset: targetOffset, rayLogoRect: rayLogoRect, rayLogoExit: rayLogoExit
        )
        // A prewarm can assign this state while the window is hidden and no
        // drawable is available. The reveal must retry even at the same time.
        context.coordinator.renderer?.state = state
        // Draw now, inside SwiftUI's own update, so the mark's new frame is
        // committed together with the text laid out next to it. A deferred
        // display pass would put the mark one or two frames behind the name.
        view.draw()
    }
}

enum ShaderError: LocalizedError {
    case unavailable, missingSource, missingFunction, renderFailed, invalidPixels(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Metal is unavailable on this Mac."
        case .missingSource: "The onboarding shader is missing from the app."
        case .missingFunction: "The onboarding shader could not be loaded."
        case .renderFailed: "The onboarding shader could not draw."
        case .invalidPixels(let detail): "The onboarding shader produced invalid pixels: \(detail)"
        }
    }
}

struct ShaderState: Equatable {
    var elapsed: Float = 0
    var inset: Float = 34
    var nativeSurface = false
    var variant = 0
    var targetSize: CGSize = .zero
    var targetOffset: CGPoint = .zero
    /// The mark's slot; empty means the panel's default slot.
    var rayLogoRect: CGRect = .zero
    /// 0 while the settled mark stays, 1 once it has softened and faded away.
    var rayLogoExit: Float = 0
    /// Onboarding is presented in the dark appearance; the surface color follows it.
    var darkAppearance = true
    /// Verification only: freeze temporal noise while inspecting optical transport.
    var rayPhaseLock: Float = -1
    /// Verification only: compare the fading layer with its unattenuated rays.
    var rayOpacityOverride: Float = -1
    /// Verification only: hold the collection at a fixed progress.
    var rayLogoClipOverride: Float = -1
    /// Verification only: hold the same 3D volume at a fixed flashlight tilt.
    var rayLampTurnOverride: Float = -1
}

// Layout mirrors the Metal struct, including its 8-byte alignment.
struct ShaderUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var inset: Float
    var nativeSurface: Float
    var scale: Float
    var variant: Float
    var style: Float
    var targetSize: SIMD2<Float>
    var targetOffset: SIMD2<Float>
    var tuning: SIMD4<Float>
}

/// The accepted texture: the same reach, definition, warmth and flow the
/// shader was authored with. Only the palette is Oto's.
enum OtoFlow {
    /// Metal dispatch id of the Ray style and of the Flow gesture.
    static let style: Float = 7
    static let transition: Float = 1
    /// Reach, definition, warmth, flow.
    static let tuning = SIMD4<Float>(0.35, 1.0, 0.55, 0.58)
    /// Bloom is gone before the native handoff, so it can never differ between hosts.
    static let bloomEnd: Float = 1.95
}

/// Cool silver, so the light gathers into Oto's white bars instead of
/// Firstlight's amethyst. RGB values are linear radiance.
enum OtoOnboardingPalette {
    static let silver = OtoPaletteUniforms(
        low: [0.16, 0.20, 0.30, 0],
        middle: [0.52, 0.62, 0.82, 0],
        high: [0.88, 0.92, 1, 0],
        core: [1, 1, 1, 0],
        surface: [0.021, 0.017, 0.032, 0.68],
        finish: [0.035, 0.030, 0.090, 1]
    )
}

/// Mirrors the Metal struct: six float4 slots, 96 bytes.
struct OtoPaletteUniforms {
    var low: SIMD4<Float>
    var middle: SIMD4<Float>
    var high: SIMD4<Float>
    var core: SIMD4<Float>
    // Legacy palette ABI slots. The compositor uses the native window color
    // and one global opacity, not a per-palette exposure mask.
    var surface: SIMD4<Float>
    var finish: SIMD4<Float>
}

/// Display-space native background; shared by the carrier and the native crop.
/// Resolving once per appearance avoids an AppKit color lookup on every frame.
enum OtoSurface {
    static func uniforms(dark: Bool) -> SIMD4<Float> { dark ? Self.dark : self.light }

    static func effectOpacity(at time: Float, dark: Bool) -> Float {
        let start: Float = 1.70, end: Float = 2.20
        let x = min(1, max(0, (time - start) / (end - start)))
        let progress = x * x * x * (x * (x * 6 - 15) + 10)
        return 1 + (self.uniforms(dark: dark).w - 1) * progress
    }

    // MARK: Private

    private static let light = resolve(dark: false)
    private static let dark = resolve(dark: true)

    private static func resolve(dark: Bool) -> SIMD4<Float> {
        var value = SIMD4<Float>(repeating: dark ? 0.15 : 0.93)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            if let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                value = SIMD4(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent), 1)
            }
        }
        value.w = dark ? 0.18 : 0.20
        return value
    }
}

private final class RayRenderingResources {
    init(device: MTLDevice) throws {
        let library = try Self.library(device: device)
        self.library = library
        guard let vertex = library.makeFunction(name: "fullScreenVertex"),
              let radiance = library.makeFunction(name: "rayRadianceFragment"),
              let composite = library.makeFunction(name: "rayCompositeFragment"),
              let extract = library.makeFunction(name: "rayBloomExtract"),
              let blur = library.makeFunction(name: "rayBloomBlur")
        else {
            throw ShaderError.missingFunction
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = radiance
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        self.rayPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        // The compositor writes premultiplied RGBA directly onto a transparent drawable.
        descriptor.fragmentFunction = composite
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.rayComposite = try device.makeRenderPipelineState(descriptor: descriptor)
        self.bloomExtract = try device.makeComputePipelineState(function: extract)
        self.bloomBlur = try device.makeComputePipelineState(function: blur)
        // Prepare the immutable icon before playback. Scanning its million
        // pixels in the first visible draw stalls the shared animation clock.
        self.logoAsset = try OtoLogoAsset(device: device)
    }

    let library: MTLLibrary
    let rayPipeline: MTLRenderPipelineState
    let rayComposite: MTLRenderPipelineState
    let bloomExtract: MTLComputePipelineState
    let bloomBlur: MTLComputePipelineState
    let logoAsset: OtoLogoAsset

    static func shared(device: MTLDevice) throws -> RayRenderingResources {
        self.cacheLock.lock()
        defer { cacheLock.unlock() }
        if let resources = cache[device.registryID] { return resources }
        let resources = try RayRenderingResources(device: device)
        self.cache[device.registryID] = resources
        return resources
    }

    /// The compiled shader, or the bundled source when the metallib is not
    /// there (previews, a stripped build).
    private static func library(device: MTLDevice) throws -> MTLLibrary {
        if let library = device.makeDefaultLibrary(),
           library.makeFunction(name: "rayRadianceFragment") != nil
        {
            return library
        }
        guard let url = Bundle.main.url(forResource: "Waves", withExtension: "metal") else {
            throw ShaderError.missingSource
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        return try device.makeLibrary(source: source, options: nil)
    }

    private static let cacheLock = NSLock()
    private static var cache: [UInt64: RayRenderingResources] = [:]
}

final class MetalRenderer: NSObject, MTKViewDelegate {
    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw ShaderError.unavailable }
        let resources = try RayRenderingResources.shared(device: device)
        self.library = resources.library
        self.rayPipeline = resources.rayPipeline
        self.rayComposite = resources.rayComposite
        self.bloomExtract = resources.bloomExtract
        self.bloomBlur = resources.bloomBlur
        self.logoAsset = resources.logoAsset
        self.commandQueue = queue
        super.init()
    }

    var state = ShaderState()
    var onFailure: ((String) -> Void)?
    var onPresented: ((Double) -> Void)?
    let commandQueue: MTLCommandQueue

    /// Both window hosts reuse immutable pipelines prepared before audio starts.
    /// Their command queues and render targets remain independent.
    static func prewarm(device: MTLDevice) throws {
        _ = try RayRenderingResources.shared(device: device)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        // The hidden native host follows the same state as the carrier, but
        // must not render a second light volume throughout the desktop intro.
        guard view.window?.isVisible == true,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = commandQueue.makeCommandBuffer() else { return }
        let scale = Float(view.drawableSize.width / max(view.bounds.width, 1))
        do {
            try self.encode(
                pass: pass, command: command, width: drawable.texture.width,
                height: drawable.texture.height, scale: scale
            )
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
            return
        }
        command.addCompletedHandler { [weak self] completed in
            if completed.status == .error {
                let message = completed.error?.localizedDescription ?? "Metal command failed"
                DispatchQueue.main.async { self?.onFailure?(message) }
            }
        }
        // With presentsWithTransaction, present after the GPU work is scheduled
        // so the new frame lands in this transaction together with the text.
        command.commit()
        command.waitUntilScheduled()
        let presentedTime = Double(self.state.elapsed)
        drawable.addPresentedHandler { [weak self] _ in
            DispatchQueue.main.async { self?.onPresented?(presentedTime) }
        }
        drawable.present()
    }

    /// Two passes: linear radiance into a private RGBA16Float target, then
    /// bloom, the whole-field condensation and the original mark on the drawable.
    func encode(
        pass: MTLRenderPassDescriptor,
        command: MTLCommandBuffer,
        width: Int,
        height: Int,
        scale: Float
    ) throws {
        var uniforms = ShaderUniforms(
            resolution: SIMD2(Float(width), Float(height)), time: self.state.elapsed,
            inset: self.state.inset * scale, nativeSurface: self.state.nativeSurface ? 1 : 0, scale: scale,
            variant: Float(self.state.variant), style: OtoFlow.style,
            targetSize: SIMD2(Float(self.state.targetSize.width), Float(self.state.targetSize.height)),
            targetOffset: SIMD2(Float(self.state.targetOffset.x), Float(self.state.targetOffset.y)),
            tuning: OtoFlow.tuning
        )
        let targets = try self.targets(width: width, height: height)
        let hdrPass = MTLRenderPassDescriptor()
        hdrPass.colorAttachments[0].texture = targets.radiance
        hdrPass.colorAttachments[0].loadAction = .dontCare
        hdrPass.colorAttachments[0].storeAction = .store
        guard let volume = command.makeRenderCommandEncoder(descriptor: hdrPass) else { throw ShaderError.renderFailed }
        volume.label = "Oto · 28-sample light volume"
        volume.setRenderPipelineState(self.rayPipeline)
        volume.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        var palette = OtoOnboardingPalette.silver
        volume.setFragmentBytes(&palette, length: MemoryLayout<OtoPaletteUniforms>.stride, index: 1)
        var transition = SIMD4<Float>(
            OtoFlow.transition, self.state.rayPhaseLock, self.state.darkAppearance ? 1 : 0,
            self.state.rayOpacityOverride
        )
        volume.setFragmentBytes(&transition, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        let logoAsset = self.logoAsset
        var logo = logoAsset.uniforms(state: self.state)
        volume.setFragmentBytes(&logo, length: MemoryLayout<OtoLogoUniforms>.stride, index: 3)
        volume.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        volume.endEncoding()

        if !self.state.nativeSurface, self.state.elapsed < OtoFlow.bloomEnd {
            try self.compute(command, self.bloomExtract, input: targets.radiance, output: targets.bright)
            try self.compute(
                command,
                self.bloomBlur,
                input: targets.bright,
                output: targets.scratch,
                axis: SIMD2(scale, 0)
            )
            try self.compute(
                command,
                self.bloomBlur,
                input: targets.scratch,
                output: targets.bloom,
                axis: SIMD2(0, scale)
            )
        }
        guard let composite = command.makeRenderCommandEncoder(descriptor: pass) else { throw ShaderError.renderFailed }
        composite.label = "Oto · bloom, condensation into the mark, native window color"
        composite.setRenderPipelineState(self.rayComposite)
        composite.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        var surface = OtoSurface.uniforms(dark: self.state.darkAppearance)
        composite.setFragmentBytes(&surface, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        composite.setFragmentBytes(&transition, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        composite.setFragmentBytes(&logo, length: MemoryLayout<OtoLogoUniforms>.stride, index: 3)
        composite.setFragmentTexture(targets.radiance, index: 0)
        composite.setFragmentTexture(targets.bloom, index: 1)
        composite.setFragmentTexture(logoAsset.color, index: 2)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
    }

    // MARK: Private

    private struct RayTargets {
        let radiance: MTLTexture
        let bright: MTLTexture
        let scratch: MTLTexture
        let bloom: MTLTexture
    }

    private let library: MTLLibrary
    private let rayPipeline: MTLRenderPipelineState
    private let rayComposite: MTLRenderPipelineState
    private let bloomExtract: MTLComputePipelineState
    private let bloomBlur: MTLComputePipelineState
    private let logoAsset: OtoLogoAsset
    private var rayTargets: RayTargets?

    /// Private, reusable GPU textures; bloom runs at quarter resolution.
    private func targets(width: Int, height: Int) throws -> RayTargets {
        if let rayTargets, rayTargets.radiance.width == width, rayTargets.radiance.height == height {
            return rayTargets
        }
        func texture(_ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = usage
            guard let result = commandQueue.device.makeTexture(descriptor: descriptor) else {
                throw ShaderError.renderFailed
            }
            result.label = label
            return result
        }
        let w = max(1, (width + 3) / 4), h = max(1, (height + 3) / 4)
        let result = try RayTargets(
            radiance: texture(width, height, [.renderTarget, .shaderRead], "Oto linear radiance"),
            bright: texture(w, h, [.shaderRead, .shaderWrite], "Oto bloom bright pass"),
            scratch: texture(w, h, [.shaderRead, .shaderWrite], "Oto horizontal bloom"),
            bloom: texture(w, h, [.shaderRead, .shaderWrite], "Oto vertical bloom")
        )
        self.rayTargets = result
        return result
    }

    private func compute(
        _ command: MTLCommandBuffer,
        _ pipeline: MTLComputePipelineState,
        input: MTLTexture,
        output: MTLTexture,
        axis: SIMD2<Float>? = nil
    ) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw ShaderError.renderFailed }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        if var axis { encoder.setBytes(&axis, length: MemoryLayout<SIMD2<Float>>.stride, index: 0) }
        let w = pipeline.threadExecutionWidth
        let h = min(8, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(
            MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
        )
        encoder.endEncoding()
    }
}
