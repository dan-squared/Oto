//
//  OtoMark.swift
//  Oto
//
//  The mark the intro gathers. Firstlight reads a bundled 1024 px plate; Oto
//  has no separate plate — its AppIcon *is* the mark (white bars on a near
//  black square), so the plate is lifted out before anything is drawn: the
//  light gathers into the waveform bars, never into the square behind them.
//
//  Shader seconds. The whole living field condenses into the mark between
//  `start` and `gatherEnd`; original pigment replaces it by `end`.
//

import AppKit
import ImageIO
import Metal

/// Mirrors the Metal struct: six float4 slots, 96 bytes.
struct OtoLogoUniforms {
    var frame: SIMD4<Float>
    var crop: SIMD4<Float>
    var options: SIMD4<Float>
    var timing: SIMD4<Float>
    /// Direction, brightness, diagnostic lamp-turn override (-1 live), collection end.
    var ending: SIMD4<Float>
    /// Exit of the settled mark: blur progress, blur mip levels, fade, unused.
    var exit: SIMD4<Float>
}

enum OtoLogoTiming {
    static let start = 2.05
    static let gatherEnd = 2.88
    /// Original pigment replaces the collected light as soon as it has
    /// settled; the crisp asset is on screen from `pigmentEnd`, well before
    /// the welcome starts.
    static let pigmentStart = 2.88
    static let pigmentEnd = 3.02
    static let end = 3.02
    /// Sized to sit with the 42 pt wordmark, not above it.
    static let side: CGFloat = 72
    /// Screen azimuth of the mark's fan. Must equal `logoMarkAzimuth` in Waves.metal.
    static let direction = 45.0
    /// Opacity of the collected light over the window surface, before pigment.
    static let brightness = 0.50
    /// Collection start, pigment end, pigment start, pigment start: the Soft finish.
    static let soft = SIMD4<Float>(2.05, Float(pigmentEnd), Float(pigmentStart), Float(pigmentStart))
    /// Mip levels the settled mark softens through as it leaves (≈10 pt of blur).
    static let exitBlurLevels: Float = 5
    /// The plate the icon is rasterised to.
    static let assetSide = 1024

    /// The fixed slot in the centre of the window, where the light becomes
    /// the mark. Both hosts derive it from the panel size, so the proxy and
    /// the native window agree on the optical root.
    static func rect(in panel: CGSize) -> CGRect {
        CGRect(
            x: (panel.width - self.side) / 2,
            y: (panel.height - self.side) / 2,
            width: self.side,
            height: self.side
        )
    }
}

/// The app icon, prepared once at 1024 px: its black plate is lifted out, so
/// only the waveform bars carry light.
enum OtoMarkSource {
    /// The icon's pixels with the plate removed, and the rect the bars fill.
    struct Prepared {
        let side: Int
        /// Premultiplied RGBA, plate transparent.
        var pixels: [UInt8]
        /// Normalised crop: x, y, width, height.
        let crop: SIMD4<Float>
        /// The same crop in pixels.
        let cropRect: CGRect
    }

    /// The mark as a plain image, cropped exactly as the shader crops it, so
    /// it can take the shader's place once the light has become the mark.
    static let cropped: NSImage? = {
        guard let prepared, let image = OtoMarkSource.makeImage(prepared, cropped: true) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }()

    /// The same silhouette in one flat colour. The asset's bars are white, so
    /// a light stage draws them in ink; the flying copy at the handoff uses
    /// this too, or the mark would vanish against a light menu bar.
    static func tinted(_ color: NSColor) -> NSImage? {
        guard let cropped else { return nil }
        let size = cropped.size
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        cropped.draw(
            in: NSRect(origin: .zero, size: size), from: .zero,
            operation: .destinationIn, fraction: 1
        )
        image.unlockFocus()
        return image
    }

    static let prepared: Prepared? = {
        guard let icon = OtoMarkSource.iconImage(),
              let pixels = OtoMarkSource.rasterize(icon, side: OtoLogoTiming.assetSide)
        else {
            return nil
        }
        let side = OtoLogoTiming.assetSide
        var masked = pixels
        var minX = side, minY = side, maxX = 0, maxY = 0
        for y in 0 ..< side {
            for x in 0 ..< side {
                let i = (y * side + x) * 4
                let peak = Float(max(masked[i], max(masked[i + 1], masked[i + 2]))) / 255
                // The plate is a near black square (≈ 0.067 of peak); the bars
                // are white. Ramp well above the plate so the square carries no
                // light at all, and soften only the bars' own antialiased edge.
                let t = min(1, max(0, (peak - 0.30) / (0.55 - 0.30)))
                let mask = t * t * (3 - 2 * t)
                if peak > 0.30 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                let alpha = Float(masked[i + 3]) / 255 * mask
                masked[i] = UInt8(Float(masked[i]) * mask)
                masked[i + 1] = UInt8(Float(masked[i + 1]) * mask)
                masked[i + 2] = UInt8(Float(masked[i + 2]) * mask)
                masked[i + 3] = UInt8(alpha * 255)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return Prepared(
            side: side,
            pixels: masked,
            crop: SIMD4(
                Float(rect.minX) / Float(side), Float(rect.minY) / Float(side),
                Float(rect.width) / Float(side), Float(rect.height) / Float(side)
            ),
            cropRect: rect
        )
    }()

    // MARK: Private

    /// The bundled 1024 px plate first: the same pixels the AppIcon set holds,
    /// so the mark is deterministic instead of whatever LaunchServices
    /// composed for the running bundle (whose plate carries a light rim).
    private static func iconImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "icon-1024", withExtension: "png"),
           let image = NSImage(contentsOf: url)
        {
            return image
        }
        return NSApp?.applicationIconImage
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage(named: "AppIcon")
    }

    private static func rasterize(_ image: NSImage, side: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            } else {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        return drawn ? pixels : nil
    }

    private static func makeImage(_ prepared: Prepared, cropped: Bool) -> CGImage? {
        var pixels = prepared.pixels
        return pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(
                data: bytes.baseAddress, width: prepared.side, height: prepared.side,
                bitsPerComponent: 8, bytesPerRow: prepared.side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else { return nil }
            return cropped ? image.cropping(to: prepared.cropRect) : image
        }
    }
}

/// The mark on the GPU: a mipmapped sRGB texture and the crop the shader
/// reads, prepared before playback starts.
final class OtoLogoAsset {
    init(device: MTLDevice) throws {
        guard let prepared = OtoMarkSource.prepared else { throw ShaderError.missingSource }
        let size = prepared.side
        // Mip levels let the silhouette emerge from soft lobes of light before
        // it is crisp. Level 0 is the untouched original; pigment reads only it.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: true
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let color = device.makeTexture(descriptor: descriptor) else { throw ShaderError.renderFailed }
        var pixels = prepared.pixels
        pixels.withUnsafeBytes {
            color.replace(
                region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: size * 4
            )
        }
        guard let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { throw ShaderError.renderFailed }
        blit.generateMipmaps(for: color)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        self.color = color
        self.crop = prepared.crop
        color.label = "Oto AppIcon · sRGB samples"
    }

    let color: MTLTexture
    let crop: SIMD4<Float>

    func uniforms(state: ShaderState) -> OtoLogoUniforms {
        let rect = state.rayLogoRect.isEmpty ? OtoLogoTiming.rect(in: state.targetSize) : state.rayLogoRect
        return OtoLogoUniforms(
            frame: SIMD4(
                Float(rect.midX - state.targetSize.width / 2), Float(rect.midY - state.targetSize.height / 2),
                Float(rect.width), Float(rect.height)
            ),
            crop: self.crop,
            options: SIMD4(1, state.rayLogoClipOverride, 0, Float(OtoLogoTiming.pigmentEnd)),
            timing: OtoLogoTiming.soft,
            ending: SIMD4(
                Float(OtoLogoTiming.direction * .pi / 180), Float(OtoLogoTiming.brightness),
                state.rayLampTurnOverride, Float(OtoLogoTiming.gatherEnd)
            ),
            exit: SIMD4(state.rayLogoExit, OtoLogoTiming.exitBlurLevels, state.rayLogoExit, 0)
        )
    }
}
