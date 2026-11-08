import UIKit
import Vision

struct LitterDetection {
    let crop: UIImage
    let annotated: UIImage
    let box: CGRect
    let suggestedType: String?
}

enum LitterDetector {
    static func detect(in image: UIImage) async -> LitterDetection? {
        await Task.detached(priority: .userInitiated) {
            run(on: image)
        }.value
    }

    private static func run(on image: UIImage) -> LitterDetection? {
        let upright = normalized(image, maxSide: 1600)
        guard let cgImage = upright.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let objectBox = salientBox(in: cgImage) ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let pixelBox = CGRect(
            x: objectBox.minX * width,
            y: (1 - objectBox.maxY) * height,
            width: objectBox.width * width,
            height: objectBox.height * height
        )

        let side = min(max(pixelBox.width, pixelBox.height) * 1.15, min(width, height))
        let square = CGRect(
            x: min(max(pixelBox.midX - side / 2, 0), width - side),
            y: min(max(pixelBox.midY - side / 2, 0), height - side),
            width: side,
            height: side
        ).integral

        guard let squareImage = cgImage.cropping(to: square) else { return nil }
        let crop = resized(UIImage(cgImage: squareImage), to: 512)

        return LitterDetection(
            crop: crop,
            annotated: annotated(upright, box: square),
            box: CGRect(x: square.minX / width, y: square.minY / height, width: square.width / width, height: square.height / height),
            suggestedType: crop.cgImage.flatMap(classify)
        )
    }

    private static func salientBox(in cgImage: CGImage) -> CGRect? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        let objects = request.results?.first?.salientObjects ?? []
        return objects.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }?.boundingBox
    }

    private static func classify(_ cgImage: CGImage) -> String? {
        let request = VNClassifyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: cgImage).perform([request])) != nil else { return nil }
        let labels = (request.results ?? [])
            .filter { $0.confidence > 0.05 }
            .prefix(15)
            .map { $0.identifier.lowercased() }
        for label in labels {
            let words = Set(label.split(whereSeparator: { $0 == "_" || $0 == " " }).map(String.init))
            if label.contains("bottle") { return "bottle" }
            if words.contains("can") || words.contains("tin") || label.contains("soda") { return "can" }
            if label.contains("bag") { return "bag" }
            if label.contains("cup") { return "cup" }
            if label.contains("wrapper") || label.contains("paper") || label.contains("cardboard") || label.contains("packet") { return "wrapper" }
        }
        return nil
    }

    private static func normalized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func resized(_ image: UIImage, to side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private static func annotated(_ image: UIImage, box: CGRect) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
            let lineWidth = max(image.size.width, image.size.height) * 0.008
            let path = UIBezierPath(roundedRect: box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), cornerRadius: lineWidth * 3)
            path.lineWidth = lineWidth
            UIColor(red: 1, green: 0.36, blue: 0.2, alpha: 1).setStroke()
            path.stroke()
        }
    }
}
