#!/bin/sh
# Generates AppIcon.icns procedurally — no image assets in the repo.
set -e
cd "$(dirname "$0")"

cat > /tmp/notchgolf_icon.swift <<'EOF'
import AppKit
let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let full = CGRect(x: 0, y: 0, width: s, height: s)
ctx.addPath(CGPath(roundedRect: full.insetBy(dx: 40, dy: 40), cornerWidth: 190, cornerHeight: 190, transform: nil))
ctx.clip()
ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.4, blue: 0.21, alpha: 1))
ctx.fill(full)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.04))
var x: CGFloat = 60
while x < s { ctx.fill(CGRect(x: x, y: 0, width: 55, height: s)); x += 110 }
ctx.setFillColor(CGColor(srgbRed: 0.87, green: 0.76, blue: 0.45, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 130, y: 620, width: 240, height: 240))
ctx.setFillColor(CGColor(srgbRed: 0.02, green: 0.02, blue: 0.02, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 690, y: 250, width: 170, height: 170))
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(16)
ctx.move(to: CGPoint(x: 775, y: 260)); ctx.addLine(to: CGPoint(x: 775, y: 850)); ctx.strokePath()
ctx.setFillColor(CGColor(srgbRed: 1, green: 0.32, blue: 0.28, alpha: 1))
let flag = CGMutablePath()
flag.move(to: CGPoint(x: 775, y: 850))
flag.addLine(to: CGPoint(x: 545, y: 810))
flag.addLine(to: CGPoint(x: 775, y: 765))
flag.closeSubpath()
ctx.addPath(flag); ctx.fillPath()
ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1))
ctx.fillEllipse(in: CGRect(x: 200, y: 150, width: 140, height: 140))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon_1024.png"))
EOF

swift /tmp/notchgolf_icon.swift

rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for sz in 16 32 128 256 512; do
    sips -z $sz $sz icon_1024.png --out AppIcon.iconset/icon_${sz}x${sz}.png >/dev/null
    dbl=$((sz * 2))
    sips -z $dbl $dbl icon_1024.png --out AppIcon.iconset/icon_${sz}x${sz}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset icon_1024.png
echo "AppIcon.icns generated"
