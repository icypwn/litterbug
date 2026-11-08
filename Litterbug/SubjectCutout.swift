import UIKit
import Vision
import CoreImage

/// Lifts the product out of a photo and returns it on a transparent
/// background, cropped tight.
///
/// The shipping path is `prepare` + `cutout(from:encoding:box:)`: SAM 2.1
/// tiny prompted with the scan endpoint's product box. Everything else here
/// is a fallback for when SAM or the box is unavailable, and each fallback is
/// a visible downgrade — they keep the user's fingers.
/// Ported from Tallo (unslop). Not main-actor: the compositing and Vision work run off the UI thread.
nonisolated enum SubjectCutout {

    /// Returns a background-removed, cropped cutout of the most prominent
    /// subject in `image`, or `nil` if no subject could be isolated.
    ///
    /// Plain subject lifting, exactly as Vision gives it. Attempts to drop the
    /// hand from here — picking a single instance, subtracting a person mask —
    /// shredded the product instead, which is why the box-prompted SAM path
    /// above exists. Excluding the hand is not something this function can do.
    static func cutout(from image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: cgOrientation(image.imageOrientation)
        )

        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }

            let maskedBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: true
            )
            let ciImage = CIImage(cvPixelBuffer: maskedBuffer)
            guard let outputCG = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
                return nil
            }
            return UIImage(cgImage: outputCG, scale: image.scale, orientation: .up)
        } catch {
            return nil
        }
    }

    /// Starts SAM's image encoder — the expensive stage, which needs only the
    /// photo. Kick this off when the shutter fires so it overlaps the scan
    /// request; hand the result to `cutout(from:encoding:box:)` afterwards.
    ///
    /// The uprighted image is returned alongside because the box arrives in
    /// the coordinates of the upright JPEG that was uploaded, and both stages
    /// have to agree on which pixels those are.
    static func prepare(_ image: UIImage) async -> (upright: UIImage, encoding: SAMSegmenter.Encoding)? {
        let upright = uprighted(image)
        guard let encoding = try? await SAMSegmenter.shared.encode(upright) else { return nil }
        return (upright, encoding)
    }

    /// The shipping cutout: SAM 2.1 tiny, prompted with the scan endpoint's
    /// product box, falling back to Vision if SAM is unavailable.
    ///
    /// SAM is the only stage that can exclude a hand *inside* the box — the
    /// Vision fallback can crop to the box but not carve fingers out of it, so
    /// the fallback keeps the hand and is a visible degradation, not a silent
    /// equivalent. Falls back again to a plain lift when there's no box.
    /// Which path produced the last cutout. Set alongside the existing
    /// ScanLog line so a capture can record the model without re-deriving it.
    /// Written on the same await chain that produced the image and read
    /// immediately after, so there is no window for another scan to interleave.
    static private(set) var lastMethod: String = "unknown"

    static func cutout(from image: UIImage,
                       encoding prepared: (upright: UIImage, encoding: SAMSegmenter.Encoding)?,
                       box: [Double]?) async -> UIImage? {
        let upright = prepared?.upright ?? uprighted(image)
        if let box, box.count == 4 {
            let rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
            if let encoding = prepared?.encoding,
               let samCut = await samCutout(upright, encoding: encoding, box: rect) {
                ScanLog.step("cutout", "SAM + box \(ScanLog.box(box)) -> \(ScanLog.size(samCut))")
                lastMethod = "sam+box"
                return samCut
            }
            // SAM unavailable, or no mask above threshold — the box still tells
            // us where to look, so crop and let Vision try.
            let t0 = ScanLog.now()
            if let boxed = cutout(from: upright, within: box) {
                ScanLog.step("cutout", since: t0,
                             "FALLBACK Vision+box (SAM failed) -> \(ScanLog.size(boxed)) — may keep fingers")
                lastMethod = "vision+box"
                return boxed
            }
        }
        let t0 = ScanLog.now()
        let plain = cutout(from: upright)
        ScanLog.step("cutout", since: t0,
                     "FALLBACK plain Vision lift (box=\(ScanLog.box(box))) -> \(ScanLog.size(plain)) — keeps fingers")
        lastMethod = plain == nil ? "none" : "vision"
        return plain
    }

    /// Runs SAM's decode stage and composites its mask onto the photo.
    private static func samCutout(_ upright: UIImage,
                                  encoding: SAMSegmenter.Encoding,
                                  box: CGRect) async -> UIImage? {
        guard let cg = upright.cgImage else { return nil }
        guard let result = try? await SAMSegmenter.shared.mask(from: encoding, box: box),
              !result.alpha.isEmpty
        else { return nil }

        // Already cropped to the product's bounds by the segmenter — it finds
        // them at 256x256 rather than scanning the full frame.
        let crop = result.rect
        let cw = Int(crop.width), ch = Int(crop.height)
        guard cw > 0, ch > 0, result.alpha.count == cw * ch,
              crop.maxX <= CGFloat(cg.width), crop.maxY <= CGFloat(cg.height)
        else { return nil }

        // Composite into a real RGBA bitmap rather than using
        // `CGImage.masking(_:)`. Two reasons, both of which bite silently:
        //
        //  - A CGImage *image mask* is a stencil with the opposite polarity to
        //    an alpha channel: 0 means paint, 255 means block. Handing SAM's
        //    mask (255 = product) to it keeps the background and throws the
        //    product away.
        //  - `masking()` leaves alphaInfo as the source's — .noneSkipLast for a
        //    camera frame — and carries the mask separately for draw time. The
        //    sticker border in `outlined()` is built by dilating ALPHA, so with
        //    no real alpha channel there is nothing to dilate and the border
        //    never appears.
        guard let ctx = CGContext(
            data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cropped = cg.cropping(to: crop)
        else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        guard let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: cw * ch * 4) else { return nil }

        // The mask is already crop-sized, so this walks it row-for-row.
        result.alpha.withUnsafeBufferPointer { m in
            for y in 0..<ch {
                let srcRow = y * cw
                let dstRow = y * cw * 4
                for x in 0..<cw {
                    let a = Int(m[srcRow + x])
                    let p = dstRow + x * 4
                    // Premultiplied: the colour channels scale with alpha too,
                    // or the edges fringe against whatever sits behind them.
                    buf[p]     = UInt8(Int(buf[p]) * a / 255)
                    buf[p + 1] = UInt8(Int(buf[p + 1]) * a / 255)
                    buf[p + 2] = UInt8(Int(buf[p + 2]) * a / 255)
                    buf[p + 3] = UInt8(a)
                }
            }
        }
        guard let out = ctx.makeImage() else { return nil }
        return UIImage(cgImage: out, scale: upright.scale, orientation: .up)
    }

    /// Lifts the subject, but only inside `box` — the vision model's idea of
    /// where the product is, given as fractions of the photo with a top-left
    /// origin. Vision supplies the pixel-accurate silhouette; the box supplies
    /// the semantics Vision lacks ("which of these blobs is the product").
    static func cutout(from image: UIImage, within box: [Double]) -> UIImage? {
        guard box.count == 4 else { return nil }
        // The box is in the coordinates of the JPEG the model was sent, which
        // is upright. A camera photo's `cgImage` is the raw sensor buffer —
        // landscape, with `imageOrientation` carrying the rotation — so the box
        // has to be applied to an uprighted copy or it crops the wrong region
        // and comes back on its side.
        let upright = uprighted(image)
        guard let cg = upright.cgImage else { return nil }

        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: CGFloat(box[0]) * w, y: CGFloat(box[1]) * h,
                          width: CGFloat(box[2]) * w, height: CGFloat(box[3]) * h)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard rect.width > 8, rect.height > 8, let cropped = cg.cropping(to: rect) else { return nil }
        return cutout(from: UIImage(cgImage: cropped, scale: upright.scale, orientation: .up))
    }

    /// Redraws the image so its pixel buffer matches how it displays, leaving
    /// `imageOrientation` at `.up`. A no-op when it's already upright.
    private static func uprighted(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Lifts only the Vision instance that owns `point` — the pixel the vision
    /// model says is on the product.
    ///
    /// `instanceMask` stores an instance index per pixel (0 = background), so
    /// the point is a direct lookup: whichever blob the model pointed at is the
    /// one lifted, and a hand Vision saw as its own instance is simply never
    /// selected. Returns nil if the point lands on background, so the caller
    /// can fall back to the plain lift.
    /// first — otherwise the grown edge is clipped on every side.
    static func outlined(_ cutout: UIImage, width: CGFloat = 12) -> UIImage? {
        guard width > 0, let cg = cutout.cgImage else { return cutout }
        let source = CIImage(cgImage: cg)

        // Slightly more room than the dilate needs, so the border can't touch
        // the canvas edge and read as a cut-off square.
        let pad = (width * 1.4).rounded(.up)
        let shifted = source.transformed(by: CGAffineTransform(translationX: pad, y: pad))
        let canvas = CGRect(
            x: 0, y: 0,
            width: source.extent.width + pad * 2,
            height: source.extent.height + pad * 2
        )

        // Dilate. This grows every channel, but only the alpha is used below.
        guard let dilate = CIFilter(name: "CIMorphologyMaximum") else { return cutout }
        dilate.setValue(shifted, forKey: kCIInputImageKey)
        dilate.setValue(width, forKey: kCIInputRadiusKey)
        guard let grown = dilate.outputImage else { return cutout }

        // Paint the grown silhouette white, keeping its alpha.
        let silhouette = CIImage(color: .white)
            .cropped(to: canvas)
            .applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: grown,
            ])

        // Punch the product's own silhouette out of the white, leaving a ring.
        // Compositing over the *filled* silhouette meant that on anything not
        // fully opaque — clear plastic reads as partial alpha through its whole
        // body — the white backing showed through and the product went milky.
        let ring = silhouette.applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: shifted,
        ])

        let composed = shifted.composited(over: ring).cropped(to: canvas)
        let context = CIContext()
        guard let out = context.createCGImage(composed, from: canvas) else { return cutout }
        return UIImage(cgImage: out, scale: cutout.scale, orientation: .up)
    }

    private static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}
