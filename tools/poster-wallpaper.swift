import AppKit
import CoreGraphics
// compose <poster.png> <out.png> — the poster's panels re-laid in landscape, the horizon strip grown into a tall
// panel, and every colour mapped onto the site's palette: black, the reds of #ff0000, and neutral greys.
setbuf(stdout, nil)
let a = CommandLine.arguments
let src = NSBitmapImageRep(data: NSImage(contentsOfFile: a[1])!.tiffRepresentation!)!
let SW = src.pixelsWide, SH = src.pixelsHigh
func b8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
var px = [UInt8](repeating: 0, count: SW * SH * 4)
for y in 0..<SH { for x in 0..<SW { let c = src.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    let i = (y * SW + x) * 4; px[i] = b8(c.redComponent); px[i+1] = b8(c.greenComponent); px[i+2] = b8(c.blueComponent); px[i+3] = 255 } }
func isPaper(_ x: Int, _ y: Int) -> Bool { let i = (y * SW + x) * 4
    return abs(Int(px[i]) - 232) < 22 && abs(Int(px[i+1]) - 211) < 22 && abs(Int(px[i+2]) - 199) < 24 }
// split the top-left column (x 37–338, y 28–475) at its paper gap
var gap: [Int] = []
for y in 200...400 where (37...338).filter({ isPaper($0, y) }).count > 250 { gap.append(y) }
let aBottom = gap.first! - 1, bTop = gap.last! + 1
print("A 28-\(aBottom)  B \(bTop)-475")
// ---- recolour --------------------------------------------------------------------------------------------
struct RGB { var r, g, b: Double }
func mix(_ p: RGB, _ q: RGB, _ t: Double) -> RGB { let t = max(0, min(1, t)); return RGB(r: p.r + (q.r - p.r) * t, g: p.g + (q.g - p.g) * t, b: p.b + (q.b - p.b) * t) }
func hex(_ v: Int) -> RGB { RGB(r: Double(v >> 16 & 255) / 255, g: Double(v >> 8 & 255) / 255, b: Double(v & 255) / 255) }
let nearBlack = hex(0x050000), ground = hex(0x0b0000)
let red30 = hex(0x4d0000), red80 = hex(0xcc0000), red = hex(0xff0000), blush = hex(0xffc4b8)
let grey2 = hex(0x737373), grey = hex(0xa6a6a6), mist = hex(0xe8e8e8)
let cRect = (360...662, 28...475)
func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double { let t = max(0, min(1, (x - e0) / (e1 - e0))); return t * t * (3 - 2 * t) }
/// Continuous, so gradients stay gradients: warmth (red minus blue) chooses between the red family and the greys,
/// chroma between a strong colour and a pale one, luminance where in the family. Paper reads as the palest blush.
func recolour(_ x: Int, _ y: Int) -> RGB {
    let i = (y * SW + x) * 4
    let r = Double(px[i]) / 255, g = Double(px[i+1]) / 255, b = Double(px[i+2]) / 255
    let L = 0.2126 * r + 0.7152 * g + 0.0722 * b, c = max(r, g, b) - min(r, g, b), w = r - b
    let redBase = L < 0.45 ? mix(red30, red80, (L - 0.12) / 0.33) : mix(red80, red, (L - 0.45) / 0.25)
    let warmC = mix(blush, redBase, smooth(0.12, 0.5, c))
    let coolC = mix(hex(0x3a3a3a), mist, smooth(0.25, 0.92, L))
    var out = mix(coolC, warmC, smooth(-0.05, 0.08, w))
    out = mix(nearBlack, out, smooth(0.08, 0.3, L))                                    // ink stays ink
    return out
}
// ---- layout, in poster units --------------------------------------------------------------------------------
let m = 37.0, g = 22.0, top = 58.0, bottom = 32.0      // room at the top for the menu bar
let A = CGRect(x: 37, y: 28, width: 302, height: aBottom - 28 + 1), B = CGRect(x: 37, y: bTop, width: 302, height: 475 - bTop + 1)
let C = CGRect(x: 360, y: 28, width: 303, height: 448), D = CGRect(x: 36, y: 498, width: 627, height: 84)
let E = CGRect(x: 37, y: 602, width: 302, height: 302), F = CGRect(x: 360, y: 602, width: 303, height: 302)
let colH = A.height + g + B.height + g + E.height
let tallW = 627.0
let CW = m + 302 + g + 303 + g + tallW + m, CH = top + colH + bottom
let scale = 2400.0 / CW
let OW = 2400, OH = Int((CH * scale).rounded())
print("canvas \(CW) x \(CH) → \(OW) x \(OH)")
// recoloured poster as an image
var out = [UInt8](repeating: 255, count: SW * SH * 4)
for y in 0..<SH { for x in 0..<SW { let c = recolour(x, y); let i = (y * SW + x) * 4
    out[i] = b8(c.r); out[i+1] = b8(c.g); out[i+2] = b8(c.b) } }
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let poster = CGContext(data: &out, width: SW, height: SH, bitsPerComponent: 8, bytesPerRow: SW * 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
func piece(_ r: CGRect) -> CGImage { guard let c = poster.cropping(to: r) else { print("crop failed", r, poster.width, poster.height); exit(1) }; return c }
let ctx = CGContext(data: nil, width: OW, height: OH, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
ctx.setFillColor(CGColor(srgbRed: ground.r, green: ground.g, blue: ground.b, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: OW, height: OH))
// poster coords (y down) → canvas coords (y up), scaled
func place(_ img: CGImage, _ x: Double, _ y: Double, _ w: Double, _ h: Double) {
    ctx.draw(img, in: CGRect(x: x * scale, y: Double(OH) - (y + h) * scale, width: w * scale, height: h * scale)) }
var y = top
place(piece(A), m, y, A.width, A.height); y += A.height + g
place(piece(B), m, y, B.width, B.height); y += B.height + g
place(piece(E), m, y, E.width, E.height)
let x2 = m + 302 + g
place(piece(C), x2, top, C.width, C.height); place(piece(F), x2, top + C.height + g, F.width, F.height + (colH - C.height - g - F.height))
// ---- the horizon grown into a tall panel ---------------------------------------------------------------------
let x3 = x2 + 303 + g, tallH = colH
let horizonScale = 2.0                                   // the strip's right half, twice as large: moon and rocket
let stripSrc = CGRect(x: D.minX + D.width / 2, y: D.minY, width: D.width / 2, height: D.height)
let stripH = D.height * horizonScale, stripY = top + tallH * 0.56
let tallRect = CGRect(x: x3 * scale, y: Double(OH) - (top + tallH) * scale, width: tallW * scale, height: tallH * scale)
place(piece(stripSrc), x3, stripY, tallW, stripH)
// Grow the strip upward and downward, column by column, from its own first and last rows: no seam.
let data = ctx.data!.assumingMemoryBound(to: UInt8.self), bpr0 = ctx.bytesPerRow
let px0 = Int(x3 * scale), px1 = Int((x3 + tallW) * scale)
let rowTop = Int(top * scale), rowSky = Int(stripY * scale) + 14, rowGround = Int((stripY + stripH) * scale) - 16, rowBottom = Int((top + tallH) * scale)
let night = hex(0x120000)
// The colours to grow from: a band of rows inside the strip, averaged, then blurred across, so grain doesn't streak.
func band(_ y0: Int, _ y1: Int) -> [RGB] {
    var col = (px0..<px1).map { xx -> RGB in var a = RGB(r: 0, g: 0, b: 0)
        for yy in y0..<y1 { let i = yy * bpr0 + xx * 4; a.r += Double(data[i]); a.g += Double(data[i+1]); a.b += Double(data[i+2]) }
        let n = Double(y1 - y0) * 255; return RGB(r: a.r / n, g: a.g / n, b: a.b / n) }
    for _ in 0..<3 {            // three box passes ≈ a gaussian, radius 40 px
        var out = col; let R = 40
        for i in 0..<col.count { var a = RGB(r: 0, g: 0, b: 0); var n = 0.0
            for k in max(0, i - R)...min(col.count - 1, i + R) { a.r += col[k].r; a.g += col[k].g; a.b += col[k].b; n += 1 }
            out[i] = RGB(r: a.r / n, g: a.g / n, b: a.b / n) }
        col = out }
    return col }
let skyCols = band(rowSky, rowSky + 10), groundCols = band(rowGround - 10, rowGround)
for (k, xx) in (px0..<px1).enumerated() {
    let sky = skyCols[k], grd = groundCols[k]
    for yy in rowTop..<rowSky { let t = Double(yy - rowTop) / Double(rowSky - rowTop); let c = mix(night, sky, pow(t, 1.8)); let i = yy * bpr0 + xx * 4
        data[i] = b8(c.r); data[i+1] = b8(c.g); data[i+2] = b8(c.b); data[i+3] = 255 }
    for yy in rowGround..<rowBottom { let t = Double(yy - rowGround) / Double(rowBottom - rowGround); let c = mix(mix(grd, nearBlack, 0.35), nearBlack, pow(t, 0.45)); let i = yy * bpr0 + xx * 4
        data[i] = b8(c.r); data[i+1] = b8(c.g); data[i+2] = b8(c.b); data[i+3] = 255 }
}
// stars, sparse, brighter higher up, only in the night part of the sky
var rng = SystemRandomNumberGenerator()
for _ in 0..<80 { let sx = x3 + Double.random(in: 8...(tallW - 8), using: &rng), sy = top + Double.random(in: 8...((stripY - top) * 0.6), using: &rng)
    let al = 0.3 + 0.55 * (1 - (sy - top) / ((stripY - top) * 0.6)), rr = Double.random(in: 0.5...1.3, using: &rng)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0.88, alpha: al)); ctx.fillEllipse(in: CGRect(x: sx * scale, y: Double(OH) - sy * scale, width: rr * scale, height: rr * scale)) }
// ---- grain, as the poster has, at the new resolution --------------------------------------------------------
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let bytes = rep.bitmapData!, bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
for yy in 0..<OH { for xx in 0..<OW { let n = Int.random(in: -7...7, using: &rng); let i = yy * bpr + xx * spp
    for k in 0..<3 { bytes[i + k] = UInt8(max(0, min(255, Int(bytes[i + k]) + n))) } } }
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("wrote \(a[2]) \(OW)x\(OH)")
