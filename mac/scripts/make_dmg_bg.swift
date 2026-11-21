// DMG を開いたときの背景: 生成りの地に、左 (アプリ) から右 (アプリケーション) への矢印と案内
// 使い方: swift scripts/make_dmg_bg.swift <出力.png> <倍率 1|2>
// 窓は 640×400。アイコンは左 (170,190)・右 (470,190) に置く前提 (bundle.sh と合わせる)
import AppKit

let args = CommandLine.arguments
let out = args[1]
let scale = CGFloat(Double(args.count > 2 ? args[2] : "1") ?? 1)
let W: CGFloat = 640, H: CGFloat = 400
func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// 地: 上から下へ、ごくわずかに暗くなる生成り
NSGradient(starting: color(0xFBF7EE), ending: color(0xEFE6D2))!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// 題: 上のほう (画面座標は下が 0。アイコンの中心は上から 190 = 下から 210)
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color c: NSColor, centerY: CGFloat) {
    let font = NSFont(name: weight == .bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])
    let sz = a.size()
    a.draw(at: NSPoint(x: (W - sz.width) / 2, y: centerY - sz.height / 2))
}
text("さとるエディタ", size: 24, weight: .bold, color: color(0x1B1F2E), centerY: H - 52)

// 矢印: 左右のアイコンのあいだ (x 250〜390)、アイコンの中心の高さ
let y: CGFloat = H - 190
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 252, y: y))
arrow.line(to: NSPoint(x: 372, y: y))
arrow.lineWidth = 9; arrow.lineCapStyle = .round
color(0xD23A26).setStroke(); arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 392, y: y))
head.line(to: NSPoint(x: 362, y: y + 22))
head.line(to: NSPoint(x: 362, y: y - 22))
head.close()
head.lineJoinStyle = .round; head.lineWidth = 6
color(0xD23A26).setFill(); head.fill(); head.stroke()

// 案内: 下のほう
text("左のアイコンを、右の「アプリケーション」へドラッグしてください", size: 14, weight: .regular, color: color(0x5A5040), centerY: 70)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
