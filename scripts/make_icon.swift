// さとるエディタのアイコン: 藍色の地に傾いた紙、墨の「さ」を打ったところにカーソル、行を書いているペン、右上に南京錠
// 使い方: swift scripts/make_icon.swift <出力.png> [地の色・上 RRGGBB] [地の色・下 RRGGBB]
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// 地の色 (上 → 下のグラデーション)。引数で変えられる
func argColor(_ i: Int, _ fallback: UInt32) -> NSColor {
    guard CommandLine.arguments.count > i, let v = UInt32(CommandLine.arguments[i], radix: 16) else { return color(fallback) }
    return color(v)
}
let baseTop = argColor(2, 0x3F6FB5)
let baseBottom = argColor(3, 0x1B3566)

// 下地: macOS のアイコングリッドに合わせた角丸
let inset: CGFloat = 100
let base = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let basePath = NSBezierPath(roundedRect: base, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let baseShadow = NSShadow()
baseShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
baseShadow.shadowOffset = NSSize(width: 0, height: -14)
baseShadow.shadowBlurRadius = 28
baseShadow.set()
baseBottom.setFill()
basePath.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: baseTop, ending: baseBottom)!.draw(in: basePath, angle: -90)

// 紙 (右上を折ったページ)。少し傾ける
NSGraphicsContext.saveGraphicsState()
let tilt = NSAffineTransform()
tilt.translateX(by: size / 2, yBy: size / 2)
tilt.rotate(byDegrees: 6)
tilt.translateX(by: -size / 2, yBy: -size / 2)
tilt.concat()

let paper = NSRect(x: 262, y: 187, width: 500, height: 650)
let fold: CGFloat = 96
let page = NSBezierPath()
page.move(to: NSPoint(x: paper.minX + 30, y: paper.minY))
page.line(to: NSPoint(x: paper.maxX - 30, y: paper.minY))
page.appendArc(withCenter: NSPoint(x: paper.maxX - 30, y: paper.minY + 30), radius: 30, startAngle: 270, endAngle: 0)
page.line(to: NSPoint(x: paper.maxX, y: paper.maxY - fold))
page.line(to: NSPoint(x: paper.maxX - fold, y: paper.maxY))
page.line(to: NSPoint(x: paper.minX + 30, y: paper.maxY))
page.appendArc(withCenter: NSPoint(x: paper.minX + 30, y: paper.maxY - 30), radius: 30, startAngle: 90, endAngle: 180)
page.line(to: NSPoint(x: paper.minX, y: paper.minY + 30))
page.appendArc(withCenter: NSPoint(x: paper.minX + 30, y: paper.minY + 30), radius: 30, startAngle: 180, endAngle: 270)
page.close()
NSGraphicsContext.saveGraphicsState()
let paperShadow = NSShadow()
paperShadow.shadowColor = color(0x000000, 0.4)
paperShadow.shadowOffset = NSSize(width: 0, height: -14)
paperShadow.shadowBlurRadius = 30
paperShadow.set()
color(0xFBF8EE).setFill()
page.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0xFFFDF6), ending: color(0xF1EBDA))!.draw(in: page, angle: -90)

// 折り返し
let corner = NSBezierPath()
corner.move(to: NSPoint(x: paper.maxX - fold, y: paper.maxY))
corner.line(to: NSPoint(x: paper.maxX - fold, y: paper.maxY - fold + 22))
corner.appendArc(withCenter: NSPoint(x: paper.maxX - fold + 22, y: paper.maxY - fold + 22), radius: 22, startAngle: 180, endAngle: 270)
corner.line(to: NSPoint(x: paper.maxX, y: paper.maxY - fold))
corner.close()
color(0xD9D2BE).setFill()
corner.fill()

// 主役: 墨で打った「さ」。字形の実際の外枠を測って置く
let ink = color(0x1C1B22)
let glyphFont = NSFont(name: "HiraMinProN-W6", size: 380) ?? NSFont.boldSystemFont(ofSize: 380)
var glyph = CTFontGetGlyphWithName(glyphFont, "" as CFString)
var ch: [UniChar] = Array("さ".utf16)
CTFontGetGlyphsForCharacters(glyphFont, &ch, &glyph, 1)
if let cg = CTFontCreatePathForGlyph(glyphFont, glyph, nil) {
    let bb = cg.boundingBoxOfPath
    // 外枠の左下を (紙の左 + 62, 紙の下 + 250) に合わせる
    var m = CGAffineTransform(translationX: paper.minX + 62 - bb.minX, y: paper.minY + 250 - bb.minY)
    if let moved = cg.copy(using: &m) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.addPath(moved)
        ctx.setFillColor(ink.cgColor)
        ctx.fillPath()
        // カーソル (打った字のすぐ右)
        let mb = moved.boundingBoxOfPath
        color(0x1E6BFF).setFill()
        NSBezierPath(roundedRect: NSRect(x: mb.maxX + 30, y: mb.minY - 16, width: 22, height: mb.height + 32),
                     xRadius: 9, yRadius: 9).fill()
    }
}

// 下の文字の行
let rows: [[(CGFloat, UInt32)]] = [
    [(150, 0x3A3A44), (90, 0xE0452C)], // この行の終わりにペン先が来る
    [(230, 0xA9A492)],
]
var y = paper.minY + 150
for row in rows {
    var x = paper.minX + 62
    for (w, c) in row {
        color(c).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 30), xRadius: 13, yRadius: 13).fill()
        x += w + 18
    }
    y -= 68
}
NSGraphicsContext.restoreGraphicsState()

// ペン (万年筆)。ペン先を 1 行目の終わりに置き、軸は右下へ。原点 = ペン先、+y = 軸の向き
do {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 614, yBy: 358)
    t.rotate(byDegrees: -125)
    t.concat()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShadow(offset: CGSize(width: 8, height: -12), blur: 20, color: color(0x000000, 0.42).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // 軸
    let hw: CGFloat = 40
    let barrel = NSRect(x: -hw, y: 140, width: hw * 2, height: 200)
    color(0x2B3A63).setFill()
    NSBezierPath(roundedRect: NSRect(x: -hw, y: 140, width: hw * 2, height: 232), xRadius: 30, yRadius: 30).fill()
    barrel.fill()
    color(0x46599A).setFill()
    NSBezierPath(roundedRect: NSRect(x: -hw + 12, y: 150, width: 14, height: 200), xRadius: 7, yRadius: 7).fill()
    color(0x1D2746).setFill()
    NSRect(x: hw - 22, y: 140, width: 22, height: 200).fill()
    // 金の輪
    color(0xF0C24E).setFill()
    NSRect(x: -hw - 2, y: 122, width: hw * 2 + 4, height: 20).fill()
    NSRect(x: -hw, y: 316, width: hw * 2, height: 12).fill()
    // 首 (握るところ)
    let grip = NSBezierPath()
    grip.move(to: NSPoint(x: -26, y: 72))
    grip.line(to: NSPoint(x: 26, y: 72))
    grip.line(to: NSPoint(x: 36, y: 122))
    grip.line(to: NSPoint(x: -36, y: 122))
    grip.close()
    color(0x171D30).setFill()
    grip.fill()
    // ペン先
    let nib = NSBezierPath()
    nib.move(to: NSPoint(x: 0, y: 0))
    nib.curve(to: NSPoint(x: 28, y: 74), controlPoint1: NSPoint(x: 10, y: 22), controlPoint2: NSPoint(x: 30, y: 44))
    nib.line(to: NSPoint(x: -28, y: 74))
    nib.curve(to: NSPoint(x: 0, y: 0), controlPoint1: NSPoint(x: -30, y: 44), controlPoint2: NSPoint(x: -10, y: 22))
    nib.close()
    color(0xF0C24E).setFill()
    nib.fill()
    color(0x8A6410).setStroke()
    let slit = NSBezierPath()
    slit.move(to: NSPoint(x: 0, y: 4))
    slit.line(to: NSPoint(x: 0, y: 46))
    slit.lineWidth = 4
    slit.stroke()
    color(0x8A6410).setFill()
    NSBezierPath(ovalIn: NSRect(x: -7, y: 44, width: 14, height: 14)).fill()

    ctx.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
}

// 南京錠 (右上、大きめ)。流出防止 = 暗号化して保存できることを示す
do {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 772, yBy: 722)
    t.rotate(byDegrees: -8)
    t.scale(by: 1.3)
    t.concat()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: color(0x000000, 0.4).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    // つる
    let shackle = NSBezierPath()
    shackle.move(to: NSPoint(x: -48, y: 40))
    shackle.line(to: NSPoint(x: -48, y: 78))
    shackle.appendArc(withCenter: NSPoint(x: 0, y: 78), radius: 48, startAngle: 180, endAngle: 0, clockwise: true)
    shackle.line(to: NSPoint(x: 48, y: 40))
    shackle.lineWidth = 30
    shackle.lineCapStyle = .butt
    color(0xD8DCE6).setStroke()
    shackle.stroke()
    shackle.lineWidth = 10
    color(0xFFFFFF, 0.7).setStroke()
    shackle.stroke()
    // 本体 (金色)
    let body = NSBezierPath(roundedRect: NSRect(x: -88, y: -78, width: 176, height: 136), xRadius: 30, yRadius: 30)
    NSGradient(colors: [color(0xFFE27A), color(0xF4BE3A), color(0xD9941A)])!.draw(in: body, angle: -90)
    // 上のつや
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    color(0xFFFFFF, 0.28).setFill()
    NSBezierPath(roundedRect: NSRect(x: -78, y: 22, width: 156, height: 26), xRadius: 13, yRadius: 13).fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0xA8700C).setStroke()
    body.lineWidth = 6
    body.stroke()
    // 鍵穴
    color(0x1C2644).setFill()
    NSBezierPath(ovalIn: NSRect(x: -19, y: -12, width: 38, height: 38)).fill()
    let slot = NSBezierPath()
    slot.move(to: NSPoint(x: -9, y: 4))
    slot.line(to: NSPoint(x: 9, y: 4))
    slot.line(to: NSPoint(x: 14, y: -46))
    slot.line(to: NSPoint(x: -14, y: -46))
    slot.close()
    slot.fill()
    ctx.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
