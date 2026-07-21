#!/usr/bin/env bash
# Generate AppIcon.icns programmatically (clean-room: no FastStone assets).
# Motif: near-white tile + three colorful pinwheel sails (red/green/orange),
# echoing the original FastStone identity without copying it.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="Resources/AppIcon.iconset"
ICNS="Resources/AppIcon.icns"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

TMP_SWIFT=$(mktemp -t fscapture-icon-XXXX.swift)
cat > "$TMP_SWIFT" <<'EOF'
import AppKit

let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()

let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)

// Near-white squircle tile.
let bgPath = NSBezierPath(roundedRect: full.insetBy(dx: 28, dy: 28), xRadius: 200, yRadius: 200)
NSGraphicsContext.saveGraphicsState()
bgPath.addClip()
NSGradient(colors: [
    NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.90, green: 0.91, blue: 0.92, alpha: 1),
])!.draw(in: full, angle: -90)
NSGraphicsContext.restoreGraphicsState()
NSColor(srgbRed: 0.78, green: 0.79, blue: 0.80, alpha: 1).setStroke()
bgPath.lineWidth = 10
bgPath.stroke()

// Comma/petal shape: asymmetric curved sail from pivot to tip.
func petal(pivot: CGPoint, tip: CGPoint, width: CGFloat) -> NSBezierPath {
    let dx = tip.x - pivot.x, dy = tip.y - pivot.y
    let len = max(1, sqrt(dx * dx + dy * dy))
    let nx = -dy / len, ny = dx / len
    let p = NSBezierPath()
    p.move(to: pivot)
    p.curve(to: tip,
            controlPoint1: CGPoint(x: pivot.x + dx * 0.25 + nx * width, y: pivot.y + dy * 0.25 + ny * width),
            controlPoint2: CGPoint(x: pivot.x + dx * 0.82 + nx * width * 0.85, y: pivot.y + dy * 0.82 + ny * width * 0.85))
    p.curve(to: pivot,
            controlPoint1: CGPoint(x: pivot.x + dx * 0.80 - nx * width * 0.30, y: pivot.y + dy * 0.80 - ny * width * 0.30),
            controlPoint2: CGPoint(x: pivot.x + dx * 0.25 - nx * width * 0.40, y: pivot.y + dy * 0.25 - ny * width * 0.40))
    p.close()
    return p
}

// Three sails pinwheeling out of a common hub, white gaps between.
let hub = CGPoint(x: 500, y: 470)
let sails: [(CGPoint, CGFloat, NSColor)] = [
    (CGPoint(x: 250, y: 856), 168, NSColor(srgbRed: 0.88, green: 0.19, blue: 0.16, alpha: 1)),
    (CGPoint(x: 862, y: 610), 150, NSColor(srgbRed: 0.22, green: 0.64, blue: 0.27, alpha: 1)),
    (CGPoint(x: 388, y: 158), 122, NSColor(srgbRed: 0.96, green: 0.62, blue: 0.10, alpha: 1)),
]
for (tip, w, color) in sails {
    let path = petal(pivot: hub, tip: tip, width: w)
    NSColor.white.setStroke()
    path.lineWidth = 26
    path.lineJoinStyle = .round
    path.stroke()
    color.setFill()
    path.fill()
}

img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
EOF

BASE_PNG=$(mktemp -t fscapture-icon-XXXX.png)
swift "$TMP_SWIFT" "$BASE_PNG"

for s in 16 32 128 256 512; do
  sips -z $s $s "$BASE_PNG" --out "$OUT_DIR/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$BASE_PNG" --out "$OUT_DIR/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$OUT_DIR" -o "$ICNS"
rm -rf "$OUT_DIR" "$TMP_SWIFT" "$BASE_PNG"
echo "Generated $ICNS"
