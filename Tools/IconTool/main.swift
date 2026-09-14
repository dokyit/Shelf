import AppKit
import ShelfCore

func pngData(from image: NSImage, pixelWidth: Int, pixelHeight: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "ShelfIconTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap rep"])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ShelfIconTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    return data
}

func writePNG(_ image: NSImage, pixelSize: Int, to url: URL) throws {
    let data = try pngData(from: image, pixelWidth: pixelSize, pixelHeight: pixelSize)
    try data.write(to: url)
}

func contactSheetImage() -> NSImage {
    let columns: [(NSColor, NSColor)] = [
        (.white, .black),
        (NSColor(white: 0.16, alpha: 1), .white)
    ]
    let cellWidth: CGFloat = 190
    let cellHeight: CGFloat = 120
    let rows = 7
    let size = NSSize(width: cellWidth * CGFloat(columns.count), height: cellHeight * CGFloat(rows))

    return NSImage(size: size, flipped: false) { rect in
        for (column, colors) in columns.enumerated() {
            let (background, foreground) = colors
            for count in 0...6 {
                let cell = NSRect(
                    x: CGFloat(column) * cellWidth,
                    y: size.height - CGFloat(count + 1) * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                background.setFill()
                cell.fill()

                let glyph = MenuBarIconRenderer.shelfImage(bookCount: count, color: foreground)
                let scale: CGFloat = 4.5
                let glyphSize = NSSize(
                    width: MenuBarIconRenderer.canvasSize.width * scale,
                    height: MenuBarIconRenderer.canvasSize.height * scale
                )
                let glyphRect = NSRect(
                    x: cell.minX + (cell.width - glyphSize.width) / 2,
                    y: cell.minY + 34,
                    width: glyphSize.width,
                    height: glyphSize.height
                )
                glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)

                let label = NSAttributedString(
                    string: "\(count) book\(count == 1 ? "" : "s")",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: foreground.withAlphaComponent(0.75)
                    ]
                )
                let labelSize = label.size()
                label.draw(at: NSPoint(
                    x: cell.midX - labelSize.width / 2,
                    y: cell.minY + 12
                ))
            }
        }
        return true
    }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let outURL = URL(fileURLWithPath: outDir, isDirectory: true)
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024)
]

let iconsetURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("ShelfIconTool-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
for entry in iconSizes {
    let image = AppIconRenderer.image(size: CGFloat(entry.pixels))
    try writePNG(image, pixelSize: entry.pixels, to: iconsetURL.appendingPathComponent("\(entry.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outURL.appendingPathComponent("Shelf.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    throw NSError(domain: "ShelfIconTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "iconutil failed with status \(iconutil.terminationStatus)"])
}
try? FileManager.default.removeItem(at: iconsetURL)

let appIcon = AppIconRenderer.image(size: 1024)
try writePNG(appIcon, pixelSize: 1024, to: outURL.appendingPathComponent("AppIcon.png"))

let sheet = contactSheetImage()
let sheetData = try pngData(from: sheet, pixelWidth: Int(sheet.size.width * 2), pixelHeight: Int(sheet.size.height * 2))
try sheetData.write(to: outURL.appendingPathComponent("MenuBarIconContactSheet.png"))

print("Wrote Shelf.icns, AppIcon.png, MenuBarIconContactSheet.png to \(outURL.path)")
