//
//  NotchWallpaperRenderer.swift
//  Ice
//

import AppKit
import CryptoKit

/// Renders a copy of a wallpaper with a solid black strip across the menu bar area,
/// so the notch disappears into it.
@MainActor
enum NotchWallpaperRenderer {
    /// Everything a generated wallpaper is rendered from.
    ///
    /// Equal requests render the same image, so the file name is derived from the
    /// request. A file that already exists is the image the request would render.
    struct Request {
        /// The user's original wallpaper, or `nil` for a solid color.
        let original: URL?

        /// The width of the screen, in pixels.
        let width: Int

        /// The height of the screen, in pixels.
        let height: Int

        /// The height of the black strip, in pixels.
        let barHeight: CGFloat

        /// The radius of the top corners below the strip, in pixels, or zero for square corners.
        let cornerRadius: CGFloat

        /// The color used when the original is not a readable image.
        let fillColor: NSColor

        /// The name of the file that the request renders to.
        let fileName: String

        /// Creates the request for the given screen, or returns `nil` if the screen has no size.
        @MainActor
        init?(original: URL?, for screen: NSScreen, roundedCorners: Bool) {
            let scale = screen.backingScaleFactor
            let width = Int((screen.frame.width * scale).rounded())
            let height = Int((screen.frame.height * scale).rounded())
            guard width > 0, height > 0 else {
                return nil
            }
            let barHeight = (NotchWallpaperRenderer.menuBarHeight(for: screen) * scale).rounded(.up)
            let cornerRadius = roundedCorners ? NotchWallpaperRenderer.cornerRadius * scale : 0
            let fillColor = (NSWorkspace.shared.desktopImageOptions(for: screen)?[.fillColor] as? NSColor)?
                .usingColorSpace(.sRGB) ?? NotchWallpaperRenderer.fallbackColor

            // The original's modification date and size stand in for its contents, so
            // that editing the file in place renders a new image.
            let values = try? original?.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let key = [
                original?.standardizedFileURL.path ?? "",
                values?.contentModificationDate.map { "\($0.timeIntervalSince1970)" } ?? "",
                values?.fileSize.map { "\($0)" } ?? "",
                "\(width)x\(height)",
                "\(barHeight)",
                "\(cornerRadius)",
                "\(fillColor.redComponent),\(fillColor.greenComponent),\(fillColor.blueComponent)",
            ].joined(separator: "\n")
            let hex = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()

            self.original = original
            self.width = width
            self.height = height
            self.barHeight = barHeight
            self.cornerRadius = cornerRadius
            self.fillColor = fillColor
            self.fileName = "notch-\(hex).png"
        }
    }

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

    /// Renders the wallpaper for the given request and returns it as PNG data.
    ///
    /// The canvas starts black, and the original is drawn aspect-filled inside a clip
    /// that leaves the menu bar strip (and, optionally, the top corners) black.
    static func render(_ request: Request) -> Data? {
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: request.width,
                height: request.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        let canvas = CGRect(x: 0, y: 0, width: request.width, height: request.height)
        context.interpolationQuality = .high

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(canvas)

        let wallpaperArea = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height - request.barHeight)
        context.saveGState()
        if request.cornerRadius > 0 {
            context.addPath(roundedTopPath(in: wallpaperArea, radius: request.cornerRadius))
            context.clip()
        } else {
            context.clip(to: wallpaperArea)
        }

        if
            let image = loadImage(request.original),
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
            context.setFillColor(request.fillColor.cgColor)
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
