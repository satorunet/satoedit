// さとるエディタのアイコン: 角を折った原稿用紙。右の列に明朝の「さとる」を縦書き
// 使い方: swift scripts/make_icon.swift <出力.png> [未使用 RRGGBB] [罫線の色 RRGGBB] [invert]
//   罫線の色が色ちがいの色になる (本物の原稿用紙と同じく、朱・緑・藍など)。字はいつも墨
//   invert をつけると、濃い紙に生成りの罫線と字になる (墨)
import AppKit

let S: CGFloat = 1024
let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
let lineHex: UInt32 = args.count > 3 ? (UInt32(args[3], radix: 16) ?? 0xC8553D) : 0xC8553D
let invert = args.count > 4 && args[4] == "invert"
let paper = invert ? color(0x2A2D36) : color(0xFBF7EE)
let foldColor = invert ? color(0x4A4E57) : color(0xE3D8C0)
let rule = invert ? color(0xD9CBB0) : color(lineHex)
let ink = invert ? color(0xFBF7EE) : color(0x1B1F2E)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 紙 (縦書きは右上から書くので、左上の角を折る)
let r = NSRect(x: 190, y: 110, width: 644, height: 800), fold: CGFloat = 150, radius: CGFloat = 46
let p = NSBezierPath()
p.move(to: P(r.minX + radius, r.minY)); p.line(to: P(r.maxX - radius, r.minY))
p.appendArc(withCenter: P(r.maxX - radius, r.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
p.line(to: P(r.maxX, r.maxY - radius))
p.appendArc(withCenter: P(r.maxX - radius, r.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
p.line(to: P(r.minX + fold, r.maxY)); p.line(to: P(r.minX, r.maxY - fold))
p.line(to: P(r.minX, r.minY + radius))
p.appendArc(withCenter: P(r.minX + radius, r.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
p.close()
// まわりの影: 広くやわらかい影と、すぐ下の濃い影を重ねて、紙を浮き上がらせる
for (alpha, dy, blur) in [(CGFloat(0.30), CGFloat(-26), CGFloat(46)), (0.38, -8, 12)] {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(alpha); shadow.shadowOffset = NSSize(width: 0, height: dy); shadow.shadowBlurRadius = blur
    shadow.set()
    paper.setFill(); p.fill()
    NSGraphicsContext.restoreGraphicsState()
}
// 紙の面: 上から下へ、ごくわずかに暗くする
NSGradient(starting: paper, ending: invert ? color(0x20232B) : color(0xF1E9D8))!.draw(in: p, angle: -90)

// マス目: 3 列 × 4 行。マスの左にふりがなの細い欄、外側に太い枠 (アプリの原稿用紙と同じ作り)
let cols = 3, rows = 4
let cell: CGFloat = 150, strip: CGFloat = 34, pitch = cell + strip
let gridW = pitch * CGFloat(cols) - strip, gridH = cell * CGFloat(rows)
let gx = r.midX - gridW / 2, gy = r.midY - gridH / 2 - 10
NSGraphicsContext.saveGraphicsState()
p.addClip()
rule.setStroke()
let thin = NSBezierPath()
thin.lineWidth = 9
for c in 0..<cols {
    let x = gx + CGFloat(c) * pitch
    for vx in [x, x + cell] { thin.move(to: P(vx, gy)); thin.line(to: P(vx, gy + gridH)) }
    for k in 1..<rows {
        let y = gy + CGFloat(k) * cell
        thin.move(to: P(x, y)); thin.line(to: P(x + cell, y))
    }
}
thin.stroke()
let frame = NSBezierPath(rect: NSRect(x: gx, y: gy, width: gridW, height: gridH))
frame.lineWidth = 16
frame.stroke()

// 右の列に「さとる」(縦書き。1 字ずつマスの真ん中に)
let font = NSFont(name: "HiraMinProN-W6", size: cell * 0.78) ?? NSFont.boldSystemFont(ofSize: cell * 0.78)
let rightX = gx + CGFloat(cols - 1) * pitch
for (i, ch) in ["さ", "と", "る"].enumerated() {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: ch, attributes: [.font: font, .foregroundColor: ink]))
    ctx.textPosition = .zero // 字の大きさは、書く位置を 0 にしてから測る
    let b = CTLineGetImageBounds(line, ctx)
    let cy = gy + gridH - (CGFloat(i) + 0.5) * cell
    ctx.textPosition = CGPoint(x: rightX + cell / 2 - b.midX, y: cy - b.midY)
    CTLineDraw(line, ctx)
}
NSGraphicsContext.restoreGraphicsState()

// 紙の縁をはっきりさせる
(invert ? color(0x000000, 0.6) : color(0x6B5A3A, 0.55)).setStroke(); p.lineWidth = 7; p.lineJoinStyle = .round; p.stroke()

// 折り返した角: 紙の上に影を落とし、折り返しの面は濃い色から明るい色へ
let f = NSBezierPath()
f.move(to: P(r.minX + fold, r.maxY)); f.line(to: P(r.minX + fold, r.maxY - fold + 30))
f.appendArc(withCenter: P(r.minX + fold - 30, r.maxY - fold + 30), radius: 30, startAngle: 0, endAngle: 270, clockwise: true)
f.line(to: P(r.minX, r.maxY - fold)); f.close()
NSGraphicsContext.saveGraphicsState()
p.addClip()
let fs = NSShadow()
fs.shadowColor = NSColor.black.withAlphaComponent(0.5); fs.shadowOffset = NSSize(width: 14, height: -16); fs.shadowBlurRadius = 26
fs.set()
foldColor.setFill(); f.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: invert ? color(0x767B88) : color(0xFFFDF8), ending: invert ? color(0x3D414B) : color(0xC9B78F))!.draw(in: f, angle: 135)
(invert ? color(0x000000, 0.6) : color(0x6B5A3A, 0.6)).setStroke(); f.lineWidth = 7; f.lineJoinStyle = .round; f.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
