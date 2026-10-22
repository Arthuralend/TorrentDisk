// Рисует значок приложения 1024×1024: build.sh превращает его в AppIcon.icns.
// Запуск: swift app/make_icon.swift icon.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let background = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(red: 0.30, green: 0.55, blue: 1.00, alpha: 1),
    NSColor(red: 0.16, green: 0.30, blue: 0.85, alpha: 1),
])!.draw(in: background, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .regular)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + 40, width: s.width, height: s.height))
}

let arrowConfig = NSImage.SymbolConfiguration(pointSize: 170, weight: .bold)
    .applying(.init(paletteColors: [NSColor(red: 0.16, green: 0.30, blue: 0.85, alpha: 1)]))
if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
    .withSymbolConfiguration(arrowConfig) {
    let s = arrow.size
    let circle = NSRect(x: (size - 300) / 2, y: 170, width: 300, height: 300)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: circle).fill()
    arrow.draw(in: NSRect(x: circle.midX - s.width / 2, y: circle.midY - s.height / 2, width: s.width, height: s.height))
}

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
