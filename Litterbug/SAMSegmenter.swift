import UIKit
import CoreML
import CoreImage
import Accelerate

/// Segment Anything 2.1 (tiny), running on device, prompted with the litter box
/// Gemini returns (ported from Tallo, which prompts it with its scan endpoint's product box).
///
/// Why this and not Vision's subject lift: Vision has no notion of *which*
/// blob is the product, so a hand holding the item comes along with it. SAM
/// takes the box as a prompt and segments only what's inside it — measured
/// across four hand-held product photos, box-prompted SAM produced a clean,
/// finger-free cutout on all four where the plain lift produced none.
///
/// Apple ships this as three ANE-optimised Core ML packages (~76 MB total):
/// encode the image once, encode the prompt, then decode a mask. The encoder
/// is ~85% of the weight and the only expensive stage.
///
/// MobileSAM (40 MB) matched this on quality once the box was good, so the
/// size is buying ANE-tuned official weights rather than accuracy. Revisit if
/// bundle size ever becomes the binding constraint.
actor SAMSegmenter {

    static let shared = SAMSegmenter()

    /// SAM 2's image encoder takes a fixed square. The photo is stretched to
    /// fit rather than letterboxed, and the box is stretched identically, so
    /// the distortion cancels when the mask is scaled back out.
    private static let inputSide = 1024

    /// SAM emits mask logits at a fixed 256x256 regardless of input size.
    private static let maskSide = 256

    /// Corner labels SAM uses for a box prompt: 2 = top-left, 3 = bottom-right.
    /// (0 and 1 are background/foreground *point* clicks — different meaning.)
    private static let topLeftLabel: Double = 2
    private static let bottomRightLabel: Double = 3

    private var encoder: MLModel?
    private var prompt: MLModel?
    private var decoder: MLModel?

    /// Loads all three models, or none of them.
    ///
    /// The guard checks every model, not just the encoder, and the properties
    /// are assigned only once all three have loaded. Previously a throw
    /// partway through left `encoder` set and `decoder` nil, after which the
    /// `encoder == nil` guard short-circuited every retry — the actor was
    /// permanently broken and the next `decoder!` crashed.
    private func loadModels() throws {
        guard encoder == nil || prompt == nil || decoder == nil else { return }
        let t0 = ScanLog.now()

        func load(_ name: String, _ config: MLModelConfiguration) throws -> MLModel {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
                throw SAMError.modelMissing(name)
            }
            return try MLModel(contentsOf: url, configuration: config)
        }

        // Encoder: ANE-converted and compiles clean — let Core ML use the
        // Neural Engine. This is ~85% of the weight and it genuinely benefits.
        let ane = MLModelConfiguration()
        ane.computeUnits = .all

        // Prompt encoder + mask decoder: their dynamic-shape conv_transpose
        // ops FAIL ANE compilation on-device (ANECCompile CompilationFailure,
        // then "Error plan build: -1" in the device log). Under `.all` every
        // cold load pays for that doomed compile, and inference then runs on
        // a broken fallback plan — measured 3.3s for a decode that takes tens
        // of milliseconds on the GPU. Pinning them off the ANE skips the
        // failed compile at load AND gets a clean GPU plan at predict.
        let gpu = MLModelConfiguration()
        gpu.computeUnits = .cpuAndGPU

        // Into locals first: a throw here must leave the actor exactly as it
        // was, so the next call retries cleanly instead of finding a half-built
        // set it will never rebuild.
        let e = try load("SAM2_1TinyImageEncoderFLOAT16", ane)
        let p = try load("SAM2_1TinyPromptEncoderFLOAT16", gpu)
        let d = try load("SAM2_1TinyMaskDecoderFLOAT16", gpu)
        (encoder, prompt, decoder) = (e, p, d)
        ScanLog.step("SAM model load", since: t0, "3 models, once per launch")
    }

    /// The three models, or a thrown error. Never force-unwrap them: loading
    /// can genuinely fail (a missing bundle resource, a Core ML compile
    /// failure), and a crash is a much worse outcome than falling back to the
    /// Vision cutout.
    private func models() throws -> (encoder: MLModel, prompt: MLModel, decoder: MLModel) {
        try loadModels()
        guard let e = encoder, let p = prompt, let d = decoder else {
            throw SAMError.modelMissing("load produced no models")
        }
        return (e, p, d)
    }

    /// Load the models AND run one throwaway prediction, off the scan path.
    ///
    /// Loading alone is not enough. `MLModel(contentsOf:)` reads the weights,
    /// but Core ML defers building the GPU compute plan (the Metal/MPSGraph
    /// shaders) until the first actual prediction — so that cost lands on the
    /// user's first scan. Measured: decode 3.33s on the first scan after an
    /// install, 0.16s on every scan after.
    ///
    /// There is no prewarm API to call instead. Apple's own guidance is to
    /// warm by running a prediction, and as of iOS 18 there isn't even a way
    /// to ask whether a model is already cached. So we run a real pass over a
    /// dummy image: ~0.5s of GPU work at launch, against 3.2s off the first
    /// scan.
    ///
    /// The plan caches to disk keyed by the `mlmodelc` path, so a shipped app
    /// pays this once ever. It recurs in development only because ⌘R
    /// reinstalls and changes the bundle UUID.
    func warmUp() async {
        do {
            try loadModels()
            // A solid 8x8 image is enough — resizedPixelBuffer scales whatever
            // it is up to the encoder's fixed 1024², so the shapes flowing
            // through are identical to a real scan's. That is the only thing
            // that matters for building the plan.
            let t0 = ScanLog.now()
            let dummy = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
                UIColor.gray.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            let encoding = try await encode(dummy)
            _ = try await mask(from: encoding,
                               box: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
            ScanLog.step("SAM warm-up", since: t0, "compute plans built")
        } catch {
            // Best-effort, but never silent: a swallowed failure here was
            // invisible right up until a scan crashed on a nil model.
            ScanLog.fail("SAM warm-up", String(describing: error))
        }
    }

    enum SAMError: Error {
        case modelMissing(String)
        case badImage
        case noMask
    }

    /// The expensive half of the pipeline, kept separate on purpose.
    ///
    /// Encoding depends only on the photo, not on the box, so it can run
    /// while the scan endpoint is still deciding what the product is. That
    /// hides ~85% of SAM's cost behind a network call that has to happen
    /// anyway; only the cheap prompt+decode waits on the box.
    struct Encoding {
        let features: MLFeatureProvider
        let pixelSize: (width: Int, height: Int)
    }

    func encode(_ image: UIImage) async throws -> Encoding {
        let m = try models()
        guard let cg = image.cgImage,
              let buffer = Self.resizedPixelBuffer(cg, to: Self.inputSide)
        else { throw SAMError.badImage }
        // The two feats_* outputs are the high-resolution skip connections the
        // decoder needs for crisp mask edges.
        let t0 = ScanLog.now()
        let encoded = try await m.encoder.prediction(from: try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
        ScanLog.step("SAM encode", since: t0,
                     "\(cg.width)x\(cg.height) -> \(Self.inputSide)² (overlaps network)")
        return Encoding(features: encoded, pixelSize: (cg.width, cg.height))
    }

    /// Returns the product mask for `box` (fractions of the image, top-left
    /// origin), already cropped to the product's own bounds.
    func mask(from encoding: Encoding, box: CGRect) async throws -> MaskCrop {
        let m = try models()
        let t0 = ScanLog.now()
        let side = Self.inputSide
        let encoded = encoding.features

        // Encode the box as its two corners, in the encoder's 1024-space.
        // float16 to match the converted model's declared input type — Core ML
        // will cast a mismatch, but only sometimes, and silently when it does.
        let pts = try MLMultiArray(shape: [1, 2, 2], dataType: .float16)
        let lbl = try MLMultiArray(shape: [1, 2], dataType: .float16)
        let s = Double(side)
        pts[0] = NSNumber(value: Float(box.minX * s))   // top-left x
        pts[1] = NSNumber(value: Float(box.minY * s))   // top-left y
        pts[2] = NSNumber(value: Float(box.maxX * s))   // bottom-right x
        pts[3] = NSNumber(value: Float(box.maxY * s))   // bottom-right y
        lbl[0] = NSNumber(value: Float(Self.topLeftLabel))
        lbl[1] = NSNumber(value: Float(Self.bottomRightLabel))

        let prompted = try await m.prompt.prediction(from: try MLDictionaryFeatureProvider(
            dictionary: ["points": MLFeatureValue(multiArray: pts),
                         "labels": MLFeatureValue(multiArray: lbl)]))

        // Decode. Names are the converted model's, not ours: the prompt
        // encoder pluralises its outputs, the decoder does not.
        func feat(_ p: MLFeatureProvider, _ name: String) throws -> MLFeatureValue {
            guard let v = p.featureValue(for: name) else { throw SAMError.noMask }
            return v
        }
        let decoded = try await m.decoder.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": try feat(encoded, "image_embedding"),
            "sparse_embedding": try feat(prompted, "sparse_embeddings"),
            "dense_embedding": try feat(prompted, "dense_embeddings"),
            "feats_s0": try feat(encoded, "feats_s0"),
            "feats_s1": try feat(encoded, "feats_s1"),
        ]))

        guard let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = decoded.featureValue(for: "scores")?.multiArrayValue
        else { throw SAMError.noMask }

        // SAM proposes three masks at different granularities (roughly: part,
        // sub-object, whole object) and scores them. Tallo takes the top score;
        // Litterbug picks the mask that best FILLS the box (IoU of the mask's
        // bounds with the box), with the score only as a tiebreak. Gemini's box
        // is drawn tight around the whole piece, so the right mask fills it — the
        // top-scoring one was sometimes just a part (a spoon came back as its tip).
        let boxSide = Double(Self.maskSide)
        let prompt = CGRect(x: box.minX * boxSide, y: box.minY * boxSide,
                            width: box.width * boxSide, height: box.height * boxSide)
        var best = 0
        var bestRank = -Double.infinity
        var fits: [String] = []
        for i in 0..<scores.count {
            let fill = Self.boundsIoU(masks, channel: i, with: prompt)
            let rank = fill + 0.1 * scores[i].doubleValue
            fits.append(String(format: "%.2f/%.2f", scores[i].doubleValue, fill))
            if rank > bestRank { bestRank = rank; best = i }
        }
        ScanLog.step("SAM decode", since: t0,
                     "picked mask \(best) of \(scores.count) [score/fill \(fits.joined(separator: " "))]")

        return Self.upsample(masks, channel: best, to: encoding.pixelSize)
    }

    /// How well one mask channel's bounds match the prompt box (both in 256-space): intersection over union.
    private static func boundsIoU(_ masks: MLMultiArray, channel: Int, with box: CGRect) -> Double {
        let side = maskSide
        let plane = channel * side * side
        var lo = side, ti = side, ri = -1, bi = -1
        for y in 0..<side {
            for x in 0..<side where masks[plane + y * side + x].floatValue > 0 {
                if x < lo { lo = x }
                if x > ri { ri = x }
                if y < ti { ti = y }
                if y > bi { bi = y }
            }
        }
        guard ri >= lo, bi >= ti else { return 0 }
        let bounds = CGRect(x: lo, y: ti, width: ri - lo + 1, height: bi - ti + 1)
        let inter = bounds.intersection(box)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let i = Double(inter.width * inter.height)
        return i / (Double(bounds.width * bounds.height) + Double(box.width * box.height) - i)
    }

    /// A mask covering only the product's bounding box, in full-image pixels.
    struct MaskCrop {
        let alpha: [UInt8]      // width * height, 255 = product
        let rect: CGRect        // where it sits in the full-resolution image
    }

    // MARK: - Pixel plumbing

    /// Draws `cg` into a square BGRA buffer. Stretches rather than letterboxes:
    /// the box prompt is stretched by the same factors, so the distortion is
    /// self-cancelling and no padding offsets have to be tracked.
    private static func resizedPixelBuffer(_ cg: CGImage, to side: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let pb = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pb
    }

    private static func CGColorSpaceDeviceRGB() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Turns one 256x256 channel of mask logits into an alpha mask covering
    /// just the product's bounding box.
    ///
    /// The values are logits, not probabilities — the threshold is 0, not 0.5.
    /// Thresholding before scaling would give a hard-edged staircase, so the
    /// continuous logits are scaled first and thresholded afterwards.
    private static func upsample(_ masks: MLMultiArray, channel: Int,
                                 to size: (width: Int, height: Int)) -> MaskCrop {
        let side = maskSide
        let plane = channel * side * side
        var lowRes = [Float](repeating: 0, count: side * side)

        // The converted model reports FLOAT16; read through the typed pointer
        // so we neither assume a layout nor pay for NSNumber boxing per pixel.
        switch masks.dataType {
        case .float16:
            masks.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let src = base.advanced(by: plane * MemoryLayout<UInt16>.size)
                var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src),
                                           height: vImagePixelCount(side),
                                           width: vImagePixelCount(side),
                                           rowBytes: side * MemoryLayout<UInt16>.size)
                lowRes.withUnsafeMutableBytes { dst in
                    var dstBuf = vImage_Buffer(data: dst.baseAddress,
                                               height: vImagePixelCount(side),
                                               width: vImagePixelCount(side),
                                               rowBytes: side * MemoryLayout<Float>.size)
                    vImageConvert_Planar16FtoPlanarF(&srcBuf, &dstBuf, 0)
                }
            }
        default:
            let ptr = masks.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<(side * side) { lowRes[i] = ptr[plane + i] }
        }

        // Find the product's bounds at 256x256 — 65k comparisons — instead of
        // upscaling first and scanning 12.2M. The previous version scaled the
        // whole frame with Lanczos, thresholded every pixel, then scanned every
        // pixel for the bounding box, and discarded most of that work: on a
        // 3024x4032 photo the product occupied 1988x647. Measured at 2.67s.
        var lo = side, ti = side, ri = -1, bi = -1
        for y in 0..<side {
            let row = y * side
            for x in 0..<side where lowRes[row + x] > 0 {
                if x < lo { lo = x }
                if x > ri { ri = x }
                if y < ti { ti = y }
                if y > bi { bi = y }
            }
        }
        guard ri >= lo, bi >= ti else {
            return MaskCrop(alpha: [], rect: .zero)
        }
        // One cell of margin: the mask is about to be scaled up ~12x, and
        // clipping exactly on the boundary shaves the product's own edge.
        lo = max(0, lo - 1); ti = max(0, ti - 1)
        ri = min(side - 1, ri + 1); bi = min(side - 1, bi + 1)
        let bw = ri - lo + 1, bh = bi - ti + 1

        // Map the low-res bounds onto full-resolution pixels.
        let sx = Double(size.width) / Double(side)
        let sy = Double(size.height) / Double(side)
        let rect = CGRect(x: (Double(lo) * sx).rounded(.down),
                          y: (Double(ti) * sy).rounded(.down),
                          width: (Double(bw) * sx).rounded(),
                          height: (Double(bh) * sy).rounded())
            .intersection(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let cw = Int(rect.width), ch = Int(rect.height)
        guard cw > 0, ch > 0 else { return MaskCrop(alpha: [], rect: .zero) }

        // Scale only the bounding box, not the frame. Bilinear rather than
        // Lanczos: the result is thresholded immediately, so the extra taps
        // buy nothing.
        var scaled = [Float](repeating: 0, count: cw * ch)
        lowRes.withUnsafeMutableBufferPointer { srcBuf in
            let origin = srcBuf.baseAddress!.advanced(by: ti * side + lo)
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(origin),
                                    height: vImagePixelCount(bh),
                                    width: vImagePixelCount(bw),
                                    rowBytes: side * MemoryLayout<Float>.size)
            scaled.withUnsafeMutableBytes { dstRaw in
                var dst = vImage_Buffer(data: dstRaw.baseAddress,
                                        height: vImagePixelCount(ch),
                                        width: vImagePixelCount(cw),
                                        rowBytes: cw * MemoryLayout<Float>.size)
                vImageScale_PlanarF(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        var alpha = [UInt8](repeating: 0, count: cw * ch)
        for i in 0..<scaled.count where scaled[i] > 0 { alpha[i] = 255 }
        return MaskCrop(alpha: alpha, rect: rect)
    }
}
