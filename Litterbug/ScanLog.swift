import Foundation
import UIKit

/// Pipeline timing lines for the pickup scan (Gemini box, SAM encode/decode, cutout), same calls as
/// Tallo's ScanLog so the ported SAM code logs unchanged. Console only.
nonisolated enum ScanLog {
    static func now() -> CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }

    static func step(_ name: String, since: CFAbsoluteTime? = nil, _ detail: String = "") {
        let took = since.map { String(format: " %5.0f ms", (now() - $0) * 1000) } ?? ""
        print("[scan] \(name)\(took)\(detail.isEmpty ? "" : "  \(detail)")")
    }

    static func fail(_ name: String, _ error: String) {
        print("[scan] FAIL \(name): \(error)")
    }

    static func size(_ image: UIImage?) -> String {
        guard let image, let cg = image.cgImage else { return "nil" }
        return "\(cg.width)x\(cg.height)"
    }

    static func box(_ b: [Double]?) -> String {
        guard let b, b.count == 4 else { return "none" }
        return b.map { String(format: "%.2f", $0) }.joined(separator: ",")
    }
}
