# FSCapture for macOS

A lightweight, native **screenshot + annotation** tool for macOS — a clean-room
reimplementation inspired by the classic Windows utility *FastStone Capture*.
Built from scratch in Swift + AppKit; it contains **no** original FastStone code,
icons, or assets. All artwork is generated programmatically or uses SF Symbols.

> Personal / educational project. Feature and interaction ideas are not
> copyrightable and were reimplemented natively on top of macOS frameworks
> (ScreenCaptureKit, Vision, Core Image, PDFKit, AVFoundation).

## Features

- **Capture** — active window, window/object (hover highlight), rectangular
  region, freehand, full screen, fixed-size, multi-display; all via ScreenCaptureKit.
- **Rectangle → Clipboard** in one shortcut (no window activation).
- **Scrolling capture** — auto-scrolls a window and stitches the frames into one
  long image.
- **Auto capture** — timed interval snapshots to a folder.
- **Annotation editor** — multi-tab, vector object layer (select / move / reshape /
  undo): text (plain / boxed), lines & 10 arrow-end styles, shapes, highlighter,
  callouts, step numbers/letters, blur/pixelate, magnifier, emoji, and more.
- **Image effects** — resize, crop, rotate/flip, brightness/contrast, sharpen,
  grayscale, sepia, sketch, oil paint, reduce colors, spotlight, edge/shadow/border,
  caption bar, timestamp, reflection, watermark, make-background-transparent.
- **Screen tools** — color picker, magnifier, ruler, crosshair, focus, pin-to-screen.
- **OCR** — text recognition via Vision (offline, Chinese + English).
- **Output** — clipboard, file, auto-save (filename templates), printer, share sheet,
  multi-image → PDF, combine images.
- **`.fscx`** lossless format that keeps the editable annotation layer.
- **Bilingual UI** (中文 / English) and a lightweight built-in auto-updater.

## Requirements

- macOS 14 (Ventura) or later
- Apple Silicon or Intel

## Build

```sh
# One-time: create a stable self-signed identity so macOS keeps the
# Screen-Recording / Accessibility grants across rebuilds.
bash scripts/setup-signing.sh

# Build a signed FSCapture.app into ./build
bash scripts/make-app.sh

# Install
cp -R build/FSCapture.app /Applications/
```

On first launch, grant **Screen Recording** (required) and **Accessibility**
(only for scrolling capture) in System Settings › Privacy & Security.

## Releasing

```sh
bash scripts/make-release.sh --upload   # build, zip, write version.json, upload
```

## License

[MIT](LICENSE) © 2026 Hongbo Guo
