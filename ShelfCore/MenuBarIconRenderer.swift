import AppKit

public enum MenuBarIconRenderer {
    public static let canvasSize = NSSize(width: 22, height: 18)
    public static let strokeWidth: CGFloat = 1.3

    private static let bookHeights: [CGFloat] = [9, 6.5, 10.5, 7.5, 9.5, 6]
    private static let bookWidth: CGFloat = 2.1
    private static let bookGap: CGFloat = 0.55

    public static func shelfImage(bookCount: Int, color: NSColor = .black) -> NSImage {
        let count = max(0, min(bookCount, bookHeights.count))
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            color.setStroke()
            color.setFill()

            let shelfBottom: CGFloat = 3.4
            let shelfTop: CGFloat = 15
            let leftX: CGFloat = 2
            let rightX: CGFloat = 20

            let sides = NSBezierPath()
            sides.lineWidth = strokeWidth
            sides.lineCapStyle = .round
            sides.move(to: NSPoint(x: leftX, y: shelfBottom))
            sides.line(to: NSPoint(x: leftX, y: shelfTop))
            sides.move(to: NSPoint(x: rightX, y: shelfBottom))
            sides.line(to: NSPoint(x: rightX, y: shelfTop))
            sides.stroke()

            let bottom = NSBezierPath()
            bottom.lineWidth = strokeWidth
            bottom.lineCapStyle = .round
            bottom.move(to: NSPoint(x: leftX - 0.4, y: shelfBottom))
            bottom.line(to: NSPoint(x: rightX + 0.4, y: shelfBottom))
            bottom.stroke()

            if count > 0 {
                let totalWidth = CGFloat(count) * bookWidth + CGFloat(count - 1) * bookGap
                var x = (canvasSize.width - totalWidth) / 2
                let baseY = shelfBottom + strokeWidth / 2 + 0.2
                for index in 0..<count {
                    let height = bookHeights[index]
                    let rect = NSRect(
                        x: x,
                        y: baseY,
                        width: bookWidth,
                        height: min(height, shelfTop - baseY - 0.8)
                    )
                    let book = NSBezierPath(roundedRect: rect, xRadius: 0.5, yRadius: 0.5)
                    book.lineWidth = 1.1
                    book.fill()
                    x += bookWidth + bookGap
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    public static func separatorImage(color: NSColor = .black) -> NSImage {
        let size = NSSize(width: 12, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            color.setStroke()
            let bar = NSBezierPath()
            bar.lineWidth = strokeWidth
            bar.lineCapStyle = .round
            bar.move(to: NSPoint(x: 8.5, y: 2.5))
            bar.line(to: NSPoint(x: 8.5, y: 13.5))
            bar.stroke()

            let chevron = NSBezierPath()
            chevron.lineWidth = strokeWidth
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.move(to: NSPoint(x: 5.6, y: 5.2))
            chevron.line(to: NSPoint(x: 2.6, y: 8))
            chevron.line(to: NSPoint(x: 5.6, y: 10.8))
            chevron.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    public static func lockImage(color: NSColor = .black) -> NSImage {
        let size = NSSize(width: 12, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            color.setStroke()
            color.setFill()

            let shackle = NSBezierPath()
            shackle.lineWidth = strokeWidth
            shackle.appendArc(
                withCenter: NSPoint(x: 6, y: 7.4),
                radius: 2.1,
                startAngle: 180,
                endAngle: 360
            )
            shackle.stroke()

            let body = NSBezierPath(
                roundedRect: NSRect(x: 2.4, y: 2.2, width: 7.2, height: 5.6),
                xRadius: 1.2,
                yRadius: 1.2
            )
            body.lineWidth = strokeWidth
            body.stroke()

            let keyhole = NSBezierPath(
                ovalIn: NSRect(x: 5.25, y: 4.1, width: 1.5, height: 1.5)
            )
            keyhole.fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
