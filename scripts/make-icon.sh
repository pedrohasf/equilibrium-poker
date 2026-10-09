#!/usr/bin/env bash
# Renders assets/AppIcon.svg into build/AppIcon.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
SET="$OUT/AppIcon.iconset"
mkdir -p "$SET"
cat > "$OUT/render-icon.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let svg = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2]), size = Int(args[3])!
guard let image = NSImage(contentsOf: svg) else { fatalError("cannot load svg") }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
SWIFT
for s in 16 32 128 256 512; do
  swift "$OUT/render-icon.swift" "$ROOT/assets/AppIcon.svg" "$SET/icon_${s}x${s}.png" $s
  swift "$OUT/render-icon.swift" "$ROOT/assets/AppIcon.svg" "$SET/icon_${s}x${s}@2x.png" $((s*2))
done
iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"
cp "$SET/icon_512x512@2x.png" "$OUT/AppIcon-1024.png"
echo "Icon written to $OUT/AppIcon.icns"
