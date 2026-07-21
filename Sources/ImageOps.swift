import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Raster operations on the editor's background image. All coordinates that
/// reference regions use IMAGE PIXEL space with a TOP-LEFT origin (the same
/// space annotations live in).
enum ImageOps {
    static let ciContext = CIContext()

    private static func render(_ ci: CIImage) -> CGImage? {
        ciContext.createCGImage(ci, from: ci.extent)
    }

    private static func apply(_ image: CGImage, _ f: (CIImage) -> CIImage) -> CGImage {
        let input = CIImage(cgImage: image)
        return render(f(input).cropped(to: input.extent)) ?? image
    }

    // MARK: geometry

    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage {
        image.cropping(to: rect.integral) ?? image
    }

    static func rotate90(_ image: CGImage, clockwise: Bool) -> CGImage {
        let ci = CIImage(cgImage: image).oriented(clockwise ? .right : .left)
        return render(ci) ?? image
    }

    static func flip(_ image: CGImage, horizontal: Bool) -> CGImage {
        let ci = CIImage(cgImage: image).oriented(horizontal ? .upMirrored : .downMirrored)
        return render(ci) ?? image
    }

    static func resize(_ image: CGImage, to size: CGSize) -> CGImage {
        guard size.width >= 1, size.height >= 1 else { return image }
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage() ?? image
    }

    /// Expand (positive) or crop (negative) each canvas edge independently.
    /// New area is filled with `fill` (FastStone default: white).
    static func resizeCanvas(_ image: CGImage, left: CGFloat, top: CGFloat,
                             right: CGFloat, bottom: CGFloat,
                             fill: NSColor = .white) -> CGImage {
        let newW = Int(CGFloat(image.width) + left + right)
        let newH = Int(CGFloat(image.height) + top + bottom)
        guard newW >= 1, newH >= 1,
              let ctx = CGContext(data: nil, width: newW, height: newH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let f = fill.usingColorSpace(.sRGB) ?? fill
        ctx.setFillColor(CGColor(red: f.redComponent, green: f.greenComponent,
                                 blue: f.blueComponent, alpha: f.alphaComponent))
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        // CG bottom-left origin: x offset = left, y offset = bottom.
        ctx.draw(image, in: CGRect(x: left, y: bottom,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage() ?? image
    }

    /// Remove the horizontal (rows) or vertical (columns) strip covered by
    /// `range`, joining the remaining halves — FastStone's Remove Strip.
    /// `range` is in image pixels along the removal axis (top-left origin).
    static func removeStrip(_ image: CGImage, horizontal: Bool, range: ClosedRange<CGFloat>) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let lo = max(0, range.lowerBound), hi = min(horizontal ? h : w, range.upperBound)
        let strip = hi - lo
        guard strip >= 1 else { return image }
        let newW = horizontal ? w : w - strip
        let newH = horizontal ? h - strip : h
        guard newW >= 1, newH >= 1,
              let ctx = CGContext(data: nil, width: Int(newW), height: Int(newH),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        if horizontal {
            // Keep rows above lo and below hi (top-left coords).
            if lo >= 1, let top = image.cropping(to: CGRect(x: 0, y: 0, width: w, height: lo)) {
                ctx.draw(top, in: CGRect(x: 0, y: newH - lo, width: w, height: lo))
            }
            let bottomH = h - hi
            if bottomH >= 1, let bottom = image.cropping(to: CGRect(x: 0, y: hi, width: w, height: bottomH)) {
                ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: w, height: bottomH))
            }
        } else {
            if lo >= 1, let left = image.cropping(to: CGRect(x: 0, y: 0, width: lo, height: h)) {
                ctx.draw(left, in: CGRect(x: 0, y: 0, width: lo, height: h))
            }
            let rightW = w - hi
            if rightW >= 1, let right = image.cropping(to: CGRect(x: hi, y: 0, width: rightW, height: h)) {
                ctx.draw(right, in: CGRect(x: lo, y: 0, width: rightW, height: h))
            }
        }
        return ctx.makeImage() ?? image
    }

    /// Insert a WHITE strip of `thickness` at `position` (rows when
    /// horizontal, columns otherwise) — FastStone's Insert Strip.
    static func insertStrip(_ image: CGImage, horizontal: Bool,
                            at position: CGFloat, thickness: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let t = max(1, thickness)
        let pos = max(0, min(horizontal ? h : w, position))
        let newW = horizontal ? w : w + t
        let newH = horizontal ? h + t : h
        guard let ctx = CGContext(data: nil, width: Int(newW), height: Int(newH),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        if horizontal {
            if pos >= 1, let top = image.cropping(to: CGRect(x: 0, y: 0, width: w, height: pos)) {
                ctx.draw(top, in: CGRect(x: 0, y: newH - pos, width: w, height: pos))
            }
            let bottomH = h - pos
            if bottomH >= 1, let bottom = image.cropping(to: CGRect(x: 0, y: pos, width: w, height: bottomH)) {
                ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: w, height: bottomH))
            }
        } else {
            if pos >= 1, let left = image.cropping(to: CGRect(x: 0, y: 0, width: pos, height: h)) {
                ctx.draw(left, in: CGRect(x: 0, y: 0, width: pos, height: h))
            }
            let rightW = w - pos
            if rightW >= 1, let right = image.cropping(to: CGRect(x: pos, y: 0, width: rightW, height: h)) {
                ctx.draw(right, in: CGRect(x: pos + t, y: 0, width: rightW, height: h))
            }
        }
        return ctx.makeImage() ?? image
    }

    /// Fill `path` (image pixel coords, top-left origin) with a solid color.
    static func fillPath(_ image: CGImage, path: CGPath, color: NSColor = .white,
                         evenOdd: Bool = false) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Flip to top-left origin for the path.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let c = color.usingColorSpace(.sRGB) ?? color
        ctx.setFillColor(CGColor(red: c.redComponent, green: c.greenComponent,
                                 blue: c.blueComponent, alpha: c.alphaComponent))
        ctx.addPath(path)
        ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
        return ctx.makeImage() ?? image
    }

    /// Crop to `path`'s bounding box. With `fillWhite` (crop/copy — matches
    /// FastStone 11.1, whose editor never produces transparency) the area
    /// outside the path is white; without it (floating-selection lift) the
    /// outside stays transparent so anchoring only stamps the shape itself.
    /// Path is in image pixel coords, top-left origin.
    static func maskedCrop(_ image: CGImage, path: CGPath, fillWhite: Bool = false,
                           evenOdd: Bool = false) -> CGImage? {
        let bbox = path.boundingBox.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard bbox.width >= 1, bbox.height >= 1,
              let cropped = image.cropping(to: bbox),
              let ctx = CGContext(data: nil, width: Int(bbox.width), height: Int(bbox.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if fillWhite {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: bbox.width, height: bbox.height))
        }
        // Clip to the path translated into bbox-local, top-left-origin coords.
        ctx.translateBy(x: 0, y: bbox.height)
        ctx.scaleBy(x: 1, y: -1)
        var transform = CGAffineTransform(translationX: -bbox.minX, y: -bbox.minY)
        if let local = path.copy(using: &transform) {
            ctx.addPath(local)
            ctx.clip(using: evenOdd ? .evenOdd : .winding)
        }
        // Draw cropped image (its content is bbox region) filling the context.
        // Context currently flipped: un-flip for the raster draw.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bbox.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: bbox.width, height: bbox.height))
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Stack several images into one — vertically (top-to-bottom) or
    /// horizontally (left-to-right). Shorter images are left/top-aligned and
    /// the surrounding gaps are filled with `fill` (FastStone default: white).
    /// Powers the editor's "Combine Images into a Single Image".
    static func stack(_ images: [CGImage], horizontal: Bool,
                      spacing: Int = 0, fill: NSColor = .white) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let gap = max(0, spacing)
        let totalGap = gap * max(0, images.count - 1)
        let newW = horizontal ? images.reduce(0) { $0 + $1.width } + totalGap
                              : (images.map(\.width).max() ?? 0)
        let newH = horizontal ? (images.map(\.height).max() ?? 0)
                              : images.reduce(0) { $0 + $1.height } + totalGap
        guard newW >= 1, newH >= 1,
              let ctx = CGContext(data: nil, width: newW, height: newH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let f = fill.usingColorSpace(.sRGB) ?? fill
        ctx.setFillColor(CGColor(red: f.redComponent, green: f.greenComponent,
                                 blue: f.blueComponent, alpha: f.alphaComponent))
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        // CGContext bottom-left origin: place vertical stack from the top down,
        // horizontal stack from the left, keeping each image top/left-aligned,
        // inserting `gap` px of the fill color between images.
        var offset = 0
        for img in images {
            if horizontal {
                ctx.draw(img, in: CGRect(x: offset, y: newH - img.height, width: img.width, height: img.height))
                offset += img.width + gap
            } else {
                let y = newH - (offset + img.height)
                ctx.draw(img, in: CGRect(x: 0, y: y, width: img.width, height: img.height))
                offset += img.height + gap
            }
        }
        return ctx.makeImage()
    }

    // MARK: color

    static func adjust(_ image: CGImage, brightness: Double, contrast: Double,
                       saturation: Double, gamma: Double) -> CGImage {
        apply(image) { ci in
            var out = ci
            let controls = CIFilter.colorControls()
            controls.inputImage = out
            controls.brightness = Float(brightness)
            controls.contrast = Float(contrast)
            controls.saturation = Float(saturation)
            out = controls.outputImage ?? out
            if abs(gamma - 1.0) > 0.001 {
                let g = CIFilter.gammaAdjust()
                g.inputImage = out
                g.power = Float(gamma)
                out = g.outputImage ?? out
            }
            return out
        }
    }

    static func grayscale(_ image: CGImage) -> CGImage {
        apply(image) { ci in
            let f = CIFilter.photoEffectMono()
            f.inputImage = ci
            return f.outputImage ?? ci
        }
    }

    static func sepia(_ image: CGImage) -> CGImage {
        apply(image) { ci in
            let f = CIFilter.sepiaTone()
            f.inputImage = ci
            f.intensity = 0.9
            return f.outputImage ?? ci
        }
    }

    static func invert(_ image: CGImage) -> CGImage {
        apply(image) { ci in
            let f = CIFilter.colorInvert()
            f.inputImage = ci
            return f.outputImage ?? ci
        }
    }

    static func sharpen(_ image: CGImage, amount: Double) -> CGImage {
        apply(image) { ci in
            let f = CIFilter.sharpenLuminance()
            f.inputImage = ci
            f.sharpness = Float(amount)
            return f.outputImage ?? ci
        }
    }

    static func gaussianBlur(_ image: CGImage, radius: Double) -> CGImage {
        apply(image) { ci in
            let f = CIFilter.gaussianBlur()
            f.inputImage = ci.clampedToExtent()
            f.radius = Float(radius)
            return f.outputImage ?? ci
        }
    }

    static func pixellate(_ image: CGImage, scale: Double) -> CGImage {
        apply(image) { ci in
            let f = CIFilter.pixellate()
            f.inputImage = ci.clampedToExtent()
            f.scale = Float(scale)
            return f.outputImage ?? ci
        }
    }

    /// Blur/pixelate only `rect` (top-left-origin pixel coords).
    static func blurRegion(_ image: CGImage, rect: CGRect, pixelate: Bool, amount: Double) -> CGImage {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard clamped.width >= 1, clamped.height >= 1 else { return image }
        let region = crop(image, to: clamped)
        let processed = pixelate ? pixellate(region, scale: amount) : gaussianBlur(region, radius: amount)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let h = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: h))
        // CGContext bottom-left origin: flip the y of the region rect.
        let flipped = CGRect(x: clamped.minX, y: h - clamped.maxY,
                             width: clamped.width, height: clamped.height)
        ctx.draw(processed, in: flipped)
        return ctx.makeImage() ?? image
    }

    /// Spotlight: darken everything outside `rect`.
    static func spotlight(_ image: CGImage, rect: CGRect, dim: Double = 0.6) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let h = CGFloat(image.height)
        let full = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: h)
        ctx.draw(image, in: full)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: dim))
        let flipped = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
        // Fill everything except the spotlight rect.
        ctx.saveGState()
        ctx.addRect(full)
        ctx.addRect(flipped)
        ctx.clip(using: .evenOdd)
        ctx.fill(full)
        ctx.restoreGState()
        return ctx.makeImage() ?? image
    }

    // MARK: artistic / posterize / transparency

    /// Pencil-sketch look: grayscale → edge-detect → invert, so strong edges
    /// become dark strokes on a near-white ground (FastStone "Sketch").
    static func sketch(_ image: CGImage) -> CGImage {
        apply(image) { ci in
            let mono = CIFilter.photoEffectMono()
            mono.inputImage = ci
            let edges = CIFilter.edges()
            edges.inputImage = mono.outputImage ?? ci
            edges.intensity = 4
            let inv = CIFilter.colorInvert()
            inv.inputImage = edges.outputImage ?? ci
            return inv.outputImage ?? ci
        }
    }

    /// Oil-painting approximation: soften, then posterize into flat color
    /// regions, then a light blur to smear the region seams (FastStone
    /// "Oil Painting"). CoreImage has no true oil filter.
    static func oilPaint(_ image: CGImage) -> CGImage {
        apply(image) { ci in
            let pre = CIFilter.gaussianBlur()
            pre.inputImage = ci.clampedToExtent()
            pre.radius = 2
            let post = CIFilter.colorPosterize()
            post.inputImage = (pre.outputImage ?? ci).cropped(to: ci.extent)
            post.levels = 6
            let smear = CIFilter.gaussianBlur()
            smear.inputImage = (post.outputImage ?? ci).clampedToExtent()
            smear.radius = 1.5
            return (smear.outputImage ?? ci).cropped(to: ci.extent)
        }
    }

    /// Posterize to `levels` values per channel (FastStone "Reduce Colors").
    /// Fewer levels → fewer total colors. `CIColorPosterize` needs ≥ 2.
    static func reduceColors(_ image: CGImage, levels: Int) -> CGImage {
        apply(image) { ci in
            let f = CIFilter.colorPosterize()
            f.inputImage = ci
            f.levels = Float(max(2, levels))
            return f.outputImage ?? ci
        }
    }

    /// The top-left pixel's color — the default key color for the transparent
    /// tool (mirrors FastStone sampling the corner).
    static func topLeftColor(_ image: CGImage) -> NSColor {
        let w = image.width, h = image.height
        guard let ctx = makeContext(w, h) else { return .white }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return .white }
        let ptr = data.bindMemory(to: UInt8.self, capacity: h * ctx.bytesPerRow)
        // Bottom-left buffer: the top-left image pixel is the last row, col 0.
        let i = (h - 1) * ctx.bytesPerRow
        return NSColor(srgbRed: CGFloat(ptr[i]) / 255, green: CGFloat(ptr[i + 1]) / 255,
                       blue: CGFloat(ptr[i + 2]) / 255, alpha: 1)
    }

    /// Make every pixel within `tolerance` (0…255 per-channel distance) of
    /// `color` fully transparent — FastStone's "Make Background Transparent".
    /// Returns an alpha-bearing image so PNG export keeps the holes.
    static func makeTransparent(_ image: CGImage, color: NSColor, tolerance: Int) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = makeContext(w, h) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return image }
        let ptr = data.bindMemory(to: UInt8.self, capacity: h * ctx.bytesPerRow)
        let bpr = ctx.bytesPerRow
        let c = color.usingColorSpace(.sRGB) ?? color
        let tr = Int(round(c.redComponent * 255))
        let tg = Int(round(c.greenComponent * 255))
        let tb = Int(round(c.blueComponent * 255))
        let tol = max(0, tolerance)
        // premultipliedLast → RGBA bytes; source is opaque so RGB is un-scaled.
        for y in 0..<h {
            let row = y * bpr
            for x in 0..<w {
                let i = row + x * 4
                if abs(Int(ptr[i]) - tr) <= tol,
                   abs(Int(ptr[i + 1]) - tg) <= tol,
                   abs(Int(ptr[i + 2]) - tb) <= tol {
                    ptr[i] = 0; ptr[i + 1] = 0; ptr[i + 2] = 0; ptr[i + 3] = 0
                }
            }
        }
        return ctx.makeImage() ?? image
    }

    // MARK: - editor effects (Edge / Watermark · Caption · Stamp · Reflection)

    /// A CGColor in sRGB, honoring alpha — mirrors the manual conversion used
    /// throughout this file so device-RGB contexts get consistent colors.
    private static func cg(_ color: NSColor) -> CGColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        return CGColor(red: c.redComponent, green: c.greenComponent,
                       blue: c.blueComponent, alpha: c.alphaComponent)
    }

    /// Fresh premultiplied-RGBA context of the given pixel size.
    private static func makeContext(_ w: Int, _ h: Int) -> CGContext? {
        guard w >= 1, h >= 1 else { return nil }
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Nine-grid anchor for watermark / stamp placement (top-left conceptual).
    enum GridAnchor: Int, CaseIterable {
        case topLeft, topCenter, topRight
        case midLeft, center, midRight
        case bottomLeft, bottomCenter, bottomRight
        var label: String {
            Loc.isEnglish
                ? ["Top Left", "Top Center", "Top Right", "Mid Left", "Center", "Mid Right", "Bottom Left", "Bottom Center", "Bottom Right"][rawValue]
                : ["左上", "上中", "右上", "左中", "居中", "右中", "左下", "下中", "右下"][rawValue]
        }
        /// Origin (bottom-left CG coords) to place a `content` box inside a
        /// `container` of the given size, with `inset` from the edges.
        func origin(container: CGSize, content: CGSize, inset: CGFloat) -> CGPoint {
            let col = rawValue % 3, row = rawValue / 3
            let x: CGFloat = col == 0 ? inset
                : col == 1 ? (container.width - content.width) / 2
                : container.width - content.width - inset
            // row 0 = top → high y in bottom-left space.
            let y: CGFloat = row == 0 ? container.height - content.height - inset
                : row == 1 ? (container.height - content.height) / 2
                : inset
            return CGPoint(x: x, y: y)
        }
    }

    /// Drop-shadow edge: place the image on a larger `background`-filled canvas
    /// with a soft shadow behind it. `depth` = margin/offset, `blur` = softness,
    /// `darkness` = shadow alpha.
    static func shadowEdge(_ image: CGImage, depth: CGFloat = 24, blur: CGFloat = 12,
                           darkness: CGFloat = 0.5, background: NSColor = .white) -> CGImage {
        let margin = depth + blur
        let w = image.width, h = image.height
        let newW = w + Int(margin) * 2, newH = h + Int(margin) * 2
        guard let ctx = makeContext(newW, newH) else { return image }
        ctx.setFillColor(cg(background))
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        let imgRect = CGRect(x: margin, y: margin, width: CGFloat(w), height: CGFloat(h))
        ctx.setShadow(offset: CGSize(width: depth * 0.4, height: -depth * 0.4), blur: blur,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: darkness))
        ctx.draw(image, in: imgRect)  // shadow is cast by this draw
        return ctx.makeImage() ?? image
    }

    /// Solid border: grow the canvas by `width` on every side, filled with
    /// `color`, image centered — FastStone's simple frame.
    static func solidBorder(_ image: CGImage, width: CGFloat, color: NSColor) -> CGImage {
        let bw = max(1, width)
        let newW = image.width + Int(bw) * 2, newH = image.height + Int(bw) * 2
        guard let ctx = makeContext(newW, newH) else { return image }
        ctx.setFillColor(cg(color))
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        ctx.draw(image, in: CGRect(x: bw, y: bw, width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage() ?? image
    }

    /// Fade edge: blend the image's outer `depth` pixels into `color` on all
    /// four sides using axis-aligned gradients (classic vignette-to-white).
    static func fadeEdge(_ image: CGImage, depth: CGFloat = 40, color: NSColor = .white) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = makeContext(w, h) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = max(1, min(depth, CGFloat(min(w, h)) / 2))
        let space = CGColorSpaceCreateDeviceRGB()
        let c = color.usingColorSpace(.sRGB) ?? color
        let opaque = CGColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1)
        let clear = CGColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 0)
        guard let grad = CGGradient(colorsSpace: space, colors: [opaque, clear] as CFArray,
                                    locations: [0, 1]) else { return ctx.makeImage() ?? image }
        let fw = CGFloat(w), fh = CGFloat(h)
        // Each side: opaque at the edge → clear `d` pixels inward.
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: d, y: 0), options: [])          // left
        ctx.drawLinearGradient(grad, start: CGPoint(x: fw, y: 0), end: CGPoint(x: fw - d, y: 0), options: [])    // right
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: d), options: [])          // bottom
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: fh), end: CGPoint(x: 0, y: fh - d), options: [])    // top
        return ctx.makeImage() ?? image
    }

    /// Torn edge (rough-edge approximation): carve irregular `color` notches
    /// along all four borders so the image looks ripped.
    static func tornEdge(_ image: CGImage, depth: CGFloat = 18, color: NSColor = .white) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = makeContext(w, h) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(cg(color))
        let step = 8
        var rng = SystemRandomNumberGenerator()
        func jag() -> CGFloat { CGFloat.random(in: 0...depth, using: &rng) }
        // Top & bottom edges (walk x).
        var x = 0
        while x < w {
            ctx.fill(CGRect(x: CGFloat(x), y: CGFloat(h) - jag(), width: CGFloat(step), height: jag() + 1)) // top
            ctx.fill(CGRect(x: CGFloat(x), y: 0, width: CGFloat(step), height: jag() + 1))                   // bottom
            x += step
        }
        // Left & right edges (walk y).
        var y = 0
        while y < h {
            ctx.fill(CGRect(x: 0, y: CGFloat(y), width: jag() + 1, height: CGFloat(step)))                    // left
            ctx.fill(CGRect(x: CGFloat(w) - jag(), y: CGFloat(y), width: jag() + 1, height: CGFloat(step)))   // right
            y += step
        }
        return ctx.makeImage() ?? image
    }

    /// Composite `mark` onto `image` at a nine-grid `anchor` with `opacity`,
    /// scaled to at most `scale` of the base image's smaller side.
    static func watermark(_ image: CGImage, mark: CGImage, anchor: GridAnchor,
                          opacity: CGFloat, scale: CGFloat = 0.25, inset: CGFloat = 12) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = makeContext(w, h) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Scale the mark so its larger side fits `scale` of the base smaller side.
        let target = CGFloat(min(w, h)) * scale
        let ms = max(CGFloat(mark.width), CGFloat(mark.height))
        let factor = ms > target ? target / ms : 1
        let mSize = CGSize(width: CGFloat(mark.width) * factor, height: CGFloat(mark.height) * factor)
        let origin = anchor.origin(container: CGSize(width: w, height: h), content: mSize, inset: inset)
        ctx.setAlpha(opacity)
        ctx.draw(mark, in: CGRect(origin: origin, size: mSize))
        ctx.setAlpha(1)
        return ctx.makeImage() ?? image
    }

    /// Caption bar above or below the image (FastStone "Add Caption"). Grows the
    /// canvas by the bar, fills `background`, optional `border` frame, draws
    /// `text` in `font`/`textColor`.
    static func caption(_ image: CGImage, text: String, font: NSFont, top: Bool,
                        background: NSColor, textColor: NSColor,
                        border: NSColor? = nil) -> CGImage {
        let w = image.width
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 10
        let barH = max(Int(textSize.height + pad * 2), Int(font.pointSize + pad * 2))
        let newH = image.height + barH
        guard let ctx = makeContext(w, newH) else { return image }
        // Image occupies bottom when caption is on top, and vice-versa.
        let imgY = top ? 0 : barH
        let barY = top ? image.height : 0
        ctx.draw(image, in: CGRect(x: 0, y: imgY, width: w, height: image.height))
        ctx.setFillColor(cg(background))
        ctx.fill(CGRect(x: 0, y: barY, width: w, height: barH))
        if let border {
            ctx.setStrokeColor(cg(border))
            ctx.setLineWidth(1)
            ctx.stroke(CGRect(x: 0.5, y: CGFloat(barY) + 0.5, width: CGFloat(w) - 1, height: CGFloat(barH) - 1))
        }
        // Draw text vertically centered in the bar, left-padded.
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let ty = CGFloat(barY) + (CGFloat(barH) - textSize.height) / 2
        (text as NSString).draw(at: CGPoint(x: pad, y: ty), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage() ?? image
    }

    /// Overlay a date/time (or arbitrary) string onto the image at a corner
    /// anchor, with `color` and an optional drop shadow.
    static func dateStamp(_ image: CGImage, text: String, font: NSFont, anchor: GridAnchor,
                          color: NSColor, shadow: Bool, inset: CGFloat = 12) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = makeContext(w, h) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = anchor.origin(container: CGSize(width: w, height: h), content: size, inset: inset)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        if shadow {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.7)
            sh.shadowOffset = NSSize(width: 1, height: -1)
            sh.shadowBlurRadius = 2
            sh.set()
        }
        (text as NSString).draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage() ?? image
    }

    /// Glassy reflection: a vertically-mirrored, downward-fading copy of the
    /// image below it. `heightFraction` = reflection height as a fraction of the
    /// image; `startOpacity` = opacity at the mirror line.
    static func reflection(_ image: CGImage, heightFraction: CGFloat = 0.4,
                           startOpacity: CGFloat = 0.5, background: NSColor = .white) -> CGImage {
        let w = image.width, h = image.height
        let reflH = max(1, Int(CGFloat(h) * min(max(heightFraction, 0.05), 1)))
        let newH = h + reflH
        guard let ctx = makeContext(w, newH) else { return image }
        ctx.setFillColor(cg(background))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: newH))
        // Original on top (bottom-left origin → high y).
        ctx.draw(image, in: CGRect(x: 0, y: reflH, width: w, height: h))
        // Build the faded reflection in its own transparent layer.
        guard let layer = makeContext(w, reflH),
              let flipped = flipVertical(image) else {
            ctx.draw(image, in: CGRect(x: 0, y: reflH, width: w, height: h))
            return ctx.makeImage() ?? image
        }
        // Flipped image top row = original bottom row; align its top with the
        // mirror line (top of the reflH layer) so the seam matches.
        layer.draw(flipped, in: CGRect(x: 0, y: reflH - h, width: w, height: h))
        // Multiply alpha with a top→bottom fade (startOpacity → 0).
        let space = CGColorSpaceCreateDeviceRGB()
        let top = CGColor(red: 1, green: 1, blue: 1, alpha: startOpacity)
        let bot = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        if let grad = CGGradient(colorsSpace: space, colors: [top, bot] as CFArray, locations: [0, 1]) {
            layer.setBlendMode(.destinationIn)
            layer.drawLinearGradient(grad, start: CGPoint(x: 0, y: reflH),
                                     end: CGPoint(x: 0, y: 0), options: [])
        }
        if let reflImg = layer.makeImage() {
            ctx.draw(reflImg, in: CGRect(x: 0, y: 0, width: w, height: reflH))
        }
        return ctx.makeImage() ?? image
    }

    private static func flipVertical(_ image: CGImage) -> CGImage? {
        render(CIImage(cgImage: image).oriented(.downMirrored))
    }
}

// MARK: - color hex helpers (shared by annotations + UI)

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000FF" }
        return String(format: "#%02X%02X%02X%02X",
                      Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)), Int(round(c.alphaComponent * 255)))
    }

    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 6 { s += "FF" }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 24) & 0xFF) / 255,
                  green: CGFloat((v >> 16) & 0xFF) / 255,
                  blue: CGFloat((v >> 8) & 0xFF) / 255,
                  alpha: CGFloat(v & 0xFF) / 255)
    }
}
