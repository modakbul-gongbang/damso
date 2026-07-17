import AppKit
import SwiftUI

/// The Damso identity mark, drawn from the design tokens: an ink
/// rounded square holding hand-cut pastel blocks with a white waveform over
/// them. Drawing in code keeps the Dock icon, menu-bar icon, and exported
/// .icns pixel-identical to the token palette with no binary asset.
enum AppIconAssets {
    @MainActor
    static func applyDockIcon() {
        NSApp.applicationIconImage = dockIcon(pixels: 512)
    }

    static func menuBarImage() -> Image {
        Image(nsImage: menuBarIcon())
    }

    /// Full-color app icon used for the Dock and .icns export.
    static func dockIcon(pixels: CGFloat) -> NSImage {
        let size = NSSize(width: pixels, height: pixels)
        let image = NSImage(size: size, flipped: false) { rect in
            let scale = rect.width / 512
            let inset = 32 * scale
            let plate = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: 110 * scale, yRadius: 110 * scale)
            NSColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1).setFill()
            plate.fill()

            func block(_ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rotation: CGFloat) {
                guard let context = NSGraphicsContext.current?.cgContext else { return }
                context.saveGState()
                context.translateBy(x: (x + width / 2) * scale, y: (y + height / 2) * scale)
                context.rotate(by: rotation * .pi / 180)
                let blockRect = CGRect(x: -width / 2 * scale, y: -height / 2 * scale, width: width * scale, height: height * scale)
                let path = CGPath(roundedRect: blockRect, cornerWidth: 26 * scale, cornerHeight: 26 * scale, transform: nil)
                context.addPath(path)
                context.setFillColor(color.cgColor)
                context.fillPath()
                context.restoreGState()
            }

            // Pastel sticky notes from the block palette.
            block(NSColor(red: 0.773, green: 0.690, blue: 0.957, alpha: 1), x: 88, y: 236, width: 200, height: 152, rotation: -7) // lilac
            block(NSColor(red: 0.863, green: 0.933, blue: 0.694, alpha: 1), x: 236, y: 120, width: 192, height: 148, rotation: 5) // lime
            block(NSColor(red: 0.784, green: 0.902, blue: 0.804, alpha: 1), x: 132, y: 116, width: 132, height: 104, rotation: -3) // mint

            // White waveform bars over the blocks.
            let barHeights: [CGFloat] = [72, 128, 196, 148, 96]
            let barWidth: CGFloat = 30
            let gap: CGFloat = 24
            let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
            var x = (512 - totalWidth) / 2
            NSColor.white.setFill()
            for height in barHeights {
                let bar = NSBezierPath(
                    roundedRect: NSRect(x: x * scale, y: (256 - height / 2) * scale, width: barWidth * scale, height: height * scale),
                    xRadius: barWidth / 2 * scale,
                    yRadius: barWidth / 2 * scale
                )
                bar.fill()
                x += barWidth + gap
            }
            return true
        }
        return image
    }

    /// Monochrome template icon for the menu bar; the system recolors it for
    /// light, dark, and accented states.
    static func menuBarIcon() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let frame = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4.5, yRadius: 4.5)
            frame.lineWidth = 1.4
            NSColor.black.setStroke()
            frame.stroke()
            let barHeights: [CGFloat] = [4, 8, 11, 6]
            let barWidth: CGFloat = 1.6
            let gap: CGFloat = 1.6
            let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
            var x = (side - totalWidth) / 2
            NSColor.black.setFill()
            for height in barHeights {
                let bar = NSBezierPath(
                    roundedRect: NSRect(x: x, y: (side - height) / 2, width: barWidth, height: height),
                    xRadius: barWidth / 2,
                    yRadius: barWidth / 2
                )
                bar.fill()
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Writes the icon PNG used by the local .app bundle build. Returns the
    /// written file URL.
    @discardableResult
    static func exportPNG(to url: URL, pixels: CGFloat = 1024) throws -> URL {
        let image = dockIcon(pixels: pixels)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
