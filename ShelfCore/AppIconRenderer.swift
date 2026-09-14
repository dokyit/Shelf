import AppKit

public enum AppIconRenderer {
    private static let bookColors: [NSColor] = [
        NSColor(srgbRed: 0.77, green: 0.25, blue: 0.18, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.56, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.24, green: 0.49, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.18, green: 0.36, blue: 0.54, alpha: 1),
        NSColor(srgbRed: 0.48, green: 0.31, blue: 0.55, alpha: 1),
        NSColor(srgbRed: 0.79, green: 0.64, blue: 0.15, alpha: 1),
        NSColor(srgbRed: 0.21, green: 0.48, blue: 0.52, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.32, blue: 0.24, alpha: 1)
    ]

    public static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            draw(size: size)
            return true
        }
    }

    private static func draw(size: CGFloat) {
        let margin = size * 0.065
        let artwork = NSRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
        let radius = artwork.width * 0.2237
        let iconPath = NSBezierPath(roundedRect: artwork, xRadius: radius, yRadius: radius)

        NSGraphicsContext.current?.saveGraphicsState()
        iconPath.addClip()

        let wood = NSGradient(colors: [
            NSColor(srgbRed: 0.60, green: 0.40, blue: 0.22, alpha: 1),
            NSColor(srgbRed: 0.44, green: 0.28, blue: 0.14, alpha: 1)
        ])
        wood?.draw(in: artwork, angle: -90)

        let inner = artwork.insetBy(dx: artwork.width * 0.10, dy: artwork.width * 0.10)
        let casePath = NSBezierPath(roundedRect: inner, xRadius: artwork.width * 0.045, yRadius: artwork.width * 0.045)
        NSColor(srgbRed: 0.30, green: 0.19, blue: 0.09, alpha: 1).setFill()
        casePath.fill()

        NSColor(srgbRed: 0.20, green: 0.12, blue: 0.05, alpha: 1).setStroke()
        casePath.lineWidth = artwork.width * 0.012
        casePath.stroke()

        let plankHeight = inner.height * 0.052
        let lowerPlankY = inner.minY + inner.height * 0.055
        let upperPlankY = inner.minY + inner.height * 0.52
        for plankY in [lowerPlankY, upperPlankY] {
            let plank = NSRect(
                x: inner.minX + inner.width * 0.03,
                y: plankY,
                width: inner.width * 0.94,
                height: plankHeight
            )
            NSColor(srgbRed: 0.40, green: 0.26, blue: 0.12, alpha: 1).setFill()
            NSBezierPath(rect: plank).fill()
            NSColor(white: 1, alpha: 0.16).setFill()
            NSBezierPath(rect: NSRect(x: plank.minX, y: plank.maxY - plank.height * 0.28, width: plank.width, height: plank.height * 0.28)).fill()
        }

        drawBookRow(
            baseY: upperPlankY + plankHeight,
            maxHeight: inner.maxY - (upperPlankY + plankHeight) - inner.height * 0.05,
            width: inner.width,
            minX: inner.minX,
            seed: 0,
            lean: false
        )
        drawBookRow(
            baseY: lowerPlankY + plankHeight,
            maxHeight: upperPlankY - (lowerPlankY + plankHeight) - inner.height * 0.05,
            width: inner.width,
            minX: inner.minX,
            seed: 4,
            lean: true
        )

        let sheen = NSGradient(colors: [
            NSColor(white: 1, alpha: 0.14),
            NSColor(white: 1, alpha: 0.0)
        ])
        sheen?.draw(
            in: NSRect(x: artwork.minX, y: artwork.midY, width: artwork.width, height: artwork.height / 2),
            angle: -90
        )

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private static func drawBookRow(
        baseY: CGFloat,
        maxHeight: CGFloat,
        width: CGFloat,
        minX: CGFloat,
        seed: Int,
        lean: Bool
    ) {
        let count = 6
        let bookWidth = width * 0.088
        let gap = width * 0.017
        let groupWidth = CGFloat(count) * bookWidth + CGFloat(count - 1) * gap
        var x = minX + (width - groupWidth) / 2
        let heightFractions: [CGFloat] = [0.86, 0.62, 0.94, 0.72, 0.88, 0.66]

        for index in 0..<count {
            let height = maxHeight * heightFractions[(index + seed) % heightFractions.count]
            let color = bookColors[(index + seed) % bookColors.count]
            let rect = NSRect(x: x, y: baseY, width: bookWidth, height: height)

            if lean && index == count - 1 {
                NSGraphicsContext.current?.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: rect.minX, yBy: rect.minY)
                transform.rotate(byDegrees: -13)
                transform.translateX(by: -rect.minX, yBy: -rect.minY)
                transform.concat()
                drawSpine(rect: rect, color: color)
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                drawSpine(rect: rect, color: color)
            }
            x += bookWidth + gap
        }
    }

    private static func drawSpine(rect: NSRect, color: NSColor) {
        let spine = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.14, yRadius: rect.width * 0.14)
        color.setFill()
        spine.fill()
        NSColor(white: 0, alpha: 0.22).setStroke()
        spine.lineWidth = max(1, rect.width * 0.06)
        spine.stroke()
        NSColor(white: 1, alpha: 0.20).setFill()
        let band = NSRect(
            x: rect.minX + rect.width * 0.16,
            y: rect.maxY - rect.height * 0.20,
            width: rect.width * 0.68,
            height: rect.height * 0.075
        )
        NSBezierPath(rect: band).fill()
    }
}
