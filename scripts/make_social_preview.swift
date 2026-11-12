// Draws the repository's 1280 x 640 social preview from the documentation renders.
// Usage: swift scripts/make_social_preview.swift docs/images docs/images/social-preview.jpg
import AppKit

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let W = 1280, H = 640

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high

// AppKit's origin is bottom-left; work in top-left coordinates.
func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> NSRect {
  NSRect(x: x, y: H - y - h, width: w, height: h)
}

NSColor(calibratedRed: 0.055, green: 0.058, blue: 0.068, alpha: 1).setFill()
rect(0, 0, W, H).fill()

// Draws an image to fill the rect, cropping the excess around the centre (or around a focus point).
func fill(_ name: String, _ r: NSRect, focusX: CGFloat = 0.5, focusY: CGFloat = 0.5) {
  let image = NSImage(contentsOf: dir.appendingPathComponent(name))!
  let src = image.representations.first!
  let iw = CGFloat(src.pixelsWide), ih = CGFloat(src.pixelsHigh)
  image.size = NSSize(width: iw, height: ih)
  let scale = max(r.width / iw, r.height / ih)
  let cw = r.width / scale, ch = r.height / scale
  let cx = (iw - cw) * focusX, cy = (ih - ch) * (1 - focusY)
  image.draw(in: r, from: NSRect(x: cx, y: cy, width: cw, height: ch), operation: .copy, fraction: 1)
}

// Right side: a hero render above two spectral examples.
let gap = 6
let left = 560
let rw = W - left
let heroH = 392
fill("pavilion-hdri.jpg", rect(left, 0, rw, heroH))
let halfW = (rw - gap) / 2
let lowH = H - heroH - gap
fill("spectral-abbe-row.jpg", rect(left, heroH + gap, halfW, lowH), focusX: 0.35)
fill("spectral-newton-series.jpg", rect(left + halfW + gap, heroH + gap, rw - halfW - gap, lowH))

// A soft fade from the text panel into the pictures.
let fade = NSGradient(colors: [NSColor(calibratedRed: 0.055, green: 0.058, blue: 0.068, alpha: 1),
                               NSColor(calibratedRed: 0.055, green: 0.058, blue: 0.068, alpha: 0)])!
fade.draw(in: rect(left, 0, 70, H), angle: 0)

func text(_ s: String, _ x: Int, _ y: Int, size: CGFloat, weight: NSFont.Weight, color: NSColor, kern: CGFloat = 0) {
  let font = NSFont.systemFont(ofSize: size, weight: weight)
  let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
  let str = NSAttributedString(string: s, attributes: attrs)
  let h = str.size().height
  str.draw(at: NSPoint(x: CGFloat(x), y: CGFloat(H - y) - h))
}

let white = NSColor(calibratedWhite: 0.97, alpha: 1)
let grey = NSColor(calibratedWhite: 0.72, alpha: 1)
let dim = NSColor(calibratedWhite: 0.52, alpha: 1)
let accent = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.28, alpha: 1)

let x = 56
text("SWIFT  ·  METAL  ·  APPLE SILICON", x, 150, size: 17, weight: .semibold, color: accent, kern: 1.6)
text("Metal Vibe", x, 180, size: 68, weight: .bold, color: white, kern: -1.2)
text("Tracer", x, 254, size: 68, weight: .bold, color: white, kern: -1.2)
text("A spectral GPU path tracer for macOS", x, 350, size: 27, weight: .regular, color: grey)
text("ReSTIR DI · GI · PT   ·   OpenPBR · MaterialX", x, 420, size: 19, weight: .medium, color: dim)
text("OpenUSD · glTF · Mitsuba scenes", x, 450, size: 19, weight: .medium, color: dim)
text("github.com/gabinfor/metal-vibe-tracer", x, 560, size: 17, weight: .regular, color: dim)

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
try! data.write(to: out)
print("wrote \(out.path) (\(data.count) bytes)")
