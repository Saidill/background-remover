# Cutout

Native macOS app (SwiftUI + Apple Vision) for **removing or recoloring an image's background** and
**stamping text watermarks** on photos and documents. Everything runs on-device, with no backend.
Saved files keep the original's pixel size, DPI, orientation, color profile, bit depth and metadata.
Pixels the app doesn't change stay byte-for-byte identical (in PNG/TIFF output).

## Build
```bash
./scripts/build-app.sh            # → build/BackgroundRemover.app (no Xcode needed, macOS 15+)
open build/BackgroundRemover.app
cp -R build/BackgroundRemover.app /Applications/   # optional
swift scripts/make-icon.swift     # regenerate Resources/AppIcon.icns
```

## Use
Drop an image (or **Open** ⌘O), then **Export** (⌘S).

**Background tool (BG)**: **Keep** / **Remove** / **Color**.
- Drag across the image to compare before/after. The loupe (status bar) shows real pixels.
- **Sharpness** and **Trim halo** tune the cut edge.

**Watermark tool (MARK)**: text, font, bold, outline, size, opacity, rotation and color.
- **Single**: drag the text anywhere (it snaps to center and margins), or use the 3×3 auto-align grid plus margin.
- **Tile**: diagonal repeat across the page, with adjustable spacing.

**Output**: PNG/TIFF are lossless, JPEG/HEIC are saved at maximum quality. JPEG can't hold
transparency, so *Remove* on a JPEG defaults to PNG.

## How the edges stay sharp
Vision's mask is only about 512 px, so it is refined at full resolution with a guided filter (snaps to
real image edges) and Blur-Fusion foreground estimation (removes old-background color bleed).
Vision only runs when Remove or Color is used. Keep + watermark never touches it.

## Command line
```bash
B=build/BackgroundRemover.app/Contents/MacOS/BackgroundRemover
$B --process in.jpg out.png                                   # remove background
$B --process in.jpg out.jpg --color 438EDB --crisp 2 --trim 0.1
$B --process scan.png out.png --keep --watermark "CONFIDENTIAL" --wm-tile --wm-rotation 30 --wm-opacity 0.3
$B --process in.jpg out.jpg --keep --watermark "© Me" --wm-pos 0.9,0.95 --wm-size 4
```
