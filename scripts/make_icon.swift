// Рисует иконку приложения (градиентный «пончик»-диаграмма) в PNG нужного размера.
import AppKit

let size = CGFloat(Double(CommandLine.arguments[1])!)
let output = CommandLine.arguments[2]
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let inset = size * 0.1
let bg = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: size * 0.18, yRadius: size * 0.18)
NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.25, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.12, alpha: 1)])!.draw(in: bg, angle: -90)
let center = NSPoint(x: size / 2, y: size / 2)
let colors: [NSColor] = [.systemPurple, .systemBlue, .systemTeal, .systemGreen, .systemOrange, .systemPink]
let fractions: [CGFloat] = [0.3, 0.22, 0.16, 0.12, 0.12, 0.08]
var start: CGFloat = 90
for (ring, radius) in [(0, size * 0.30), (1, size * 0.22)] {
    start = 90 - CGFloat(ring) * 20
    for (i, f) in fractions.enumerated() {
        let end = start - 360 * f * (ring == 0 ? 1 : 0.8)
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end + 1.5, clockwise: true)
        path.lineWidth = size * 0.075
        colors[(i + ring * 2) % colors.count].withAlphaComponent(ring == 0 ? 1 : 0.75).setStroke()
        path.stroke()
        start = end
    }
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
