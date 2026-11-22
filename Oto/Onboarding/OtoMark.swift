//
//  OtoMark.swift
//  Oto
//
//  The mark the walk draws. Oto's mark is the new flower logo, shipped as a
//  template SVG in the asset catalog and as the image inside AppIcon.icon.
//  It has no opaque plate, so there is nothing to lift out: alpha alone
//  carries the silhouette, and any stage colour can tint it.
//

import AppKit

enum OtoMarkSource {
    /// The flower, already cropped by its own artwork. Falls back to the
    /// app icon on a host that cannot resolve the asset catalog image.
    static let cropped: NSImage? = NSImage(named: "OtoLogo") ?? NSImage(named: "AppIcon")

    /// The same silhouette in one flat colour. `destinationIn` keeps only
    /// the source alpha, so a light stage draws it in ink and the flying
    /// copy at the handoff stays visible against a light menu bar.
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
}
