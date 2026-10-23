//
//  NotchWallpaperRenderer.swift
//  Ice
//

import AppKit

/// Renders a copy of a wallpaper with a solid black strip across the menu bar area,
/// so the notch disappears into it.
@MainActor
enum NotchWallpaperRenderer {
    /// The color used when the wallpaper is neither a readable image nor has a fill color.
    static let fallbackColor = NSColor(srgbRed: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)

    /// The corner radius, in points, used when rounding the top corners of the wallpaper
    /// below the menu bar. Matches the window corner radius on current macOS.
    static let cornerRadius: CGFloat = 16

    /// Returns the menu bar height, in points, for the given screen.
    static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        let inset = screen.safeAreaInsets.top
        if inset > 0 {
            return inset
        }
        let measured = screen.frame.maxY - screen.visibleFrame.maxY
        if measured > 0 {
            return measured
        }
        return NSStatusBar.system.thickness + 2
    }

    /// Loads the image at the given URL as a static image.
    ///
    /// Folders use their first image, and multi-frame images (such as dynamic
    /// HEIC wallpapers) are flattened to their first frame.
    static func loadImage(_ url: URL?) -> NSImage? {
        guard var url else {
            return nil
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp"]
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let first = items
                .filter({ extensions.contains($0.pathExtension.lowercased()) })
                .min(by: { $0.lastPathComponent < $1.lastPathComponent })
            else {
                return nil
            }
            url = first
        }
        guard let image = NSImage(contentsOf: url), image.isValid else {
            return nil
        }
        if image.representations.count > 1, let rep = image.representations.first {
            let single = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
            single.addRepresentation(rep)
            return single
        }
        return image
    }

    /// Renders the wallpaper for the given screen and returns it as PNG data.
    ///
    /// The canvas starts black, and the original is drawn aspect-filled inside a clip
    /// that leaves the menu bar strip (and, optionally, the top corners) black.
    ///
    /// - Parameters:
    ///   - original: The user's original wallpaper, or `nil` for a solid color.
    ///   - screen: The screen to render the wallpaper for, at its pixel size.
    ///   - roundedCorners: Whether to round the top corners below the strip.
    static func render(original: URL?, for screen: NSScreen, roundedCorners: Bool) -> Data? {
        let scale = screen.backingScaleFactor
        let width = Int((screen.frame.width * scale).rounded())
        let height = Int((screen.frame.height * scale).rounded())
        guard
            width > 0,
            height > 0,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(canvas)

        let bar = (menuBarHeight(for: screen) * scale).rounded(.up)
        let wallpaperArea = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height - bar)
        context.saveGState()
        if roundedCorners {
            context.addPath(roundedTopPath(in: wallpaperArea, radius: cornerRadius * scale))
            context.clip()
        } else {
            context.clip(to: wallpaperArea)
        }

        if
            let image = loadImage(original),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            // Aspect-fill, centered, cropped.
            let imageWidth = CGFloat(cgImage.width)
            let imageHeight = CGFloat(cgImage.height)
            let fill = max(canvas.width / imageWidth, canvas.height / imageHeight)
            let drawWidth = imageWidth * fill
            let drawHeight = imageHeight * fill
            let rect = CGRect(
                x: (canvas.width - drawWidth) / 2,
                y: (canvas.height - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
            context.draw(cgImage, in: rect)
        } else {
            // Solid color wallpaper (or unreadable image): use the desktop fill color.
            let color = (NSWorkspace.shared.desktopImageOptions(for: screen)?[.fillColor] as? NSColor)?
                .usingColorSpace(.sRGB) ?? fallbackColor
            context.setFillColor(color.cgColor)
            context.fill(canvas)
        }
        context.restoreGState()

        guard let output = context.makeImage() else {
            return nil
        }
        return NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    }

    /// Returns a path covering the given rectangle with its top corners rounded.
    private static func roundedTopPath(in rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = min(radius, rect.width / 2, rect.height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX + radius, y: rect.maxY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - radius),
            radius: radius
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
