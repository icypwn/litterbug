import UIKit

/// One fast Gemini look at a pickup photo, made the moment the shutter fires:
///   • the box around the litter, which is SAM's prompt for the cutout (Tallo's pipeline, Gemini in place
///     of Tallo's scan endpoint),
///   • what it is, plus a few-word description (the Collection label),
///   • whether it's the litter the pin expects (the same check PickupVerifier makes, so saving doesn't need
///     a second round trip).
///
/// Flash-Lite with low thinking: ~1 s, against ~4.5–7.7 s for gemini-3.7-flash, whose default thinking
/// spends ~150 hidden tokens first. Boxes measured just as tight (including leaving a holding hand out).
enum LitterLocator {
    static let model = "gemini-3.5-flash-lite"

    struct Sighting {
        /// [x, y, width, height] fractions of the upright photo, top-left origin; nil if no litter was found.
        let box: [Double]?
        /// One of LitterType.all.
        let seenType: String
        /// It's litter, and the kind the pin expects (any kind for "litter" / the + button).
        let matches: Bool
        /// A few words, e.g. "Crushed Stella Artois can".
        let description: String
    }

    static func look(at image: UIImage, expectedType: String) async -> Sighting? {
        let key = Secrets.geminiKey
        guard !key.isEmpty else {
            ScanLog.step("gemini look", "skipped: no Secrets.geminiKey")
            return nil
        }
        // Upright and small: the box comes back in fractions, so resolution only costs upload time.
        guard let jpeg = image.downscaled(maxSide: 1024).jpegData(compressionQuality: 0.7) else { return nil }
        let t0 = ScanLog.now()

        let expected = expectedType == "litter"
            ? "any piece of litter"
            : "a \(LitterType.displayName(expectedType).lowercased()) (category \"\(expectedType)\")"
        let prompt = """
        Someone says they just picked up litter and took this photo of it (in their hand, a bag, or on the ground). \
        They're expecting \(expected).

        box_2d: [ymin, xmin, ymax, xmax], each 0-1000, tight around the main piece of litter only — not the hand \
        holding it, not the ground or background. Omit it if there's no litter.
        seenType: which ONE category that piece is:
          bottle (plastic or glass drink bottle), can (metal drink or food can), bag (plastic or paper bag),
          wrapper (snack, candy or food wrapper), cup (disposable cup, coffee cup, lid), litter (anything else).
        matches: true only if the photo really shows a piece of litter AND it is \(expected).
          False for photos of nothing, people, pets, screens, or clean objects that aren't litter.
        description: what it is in at most 6 words, e.g. "Crushed Stella Artois can".
        """
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [
                ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                ["text": prompt],
            ]]],
            "generationConfig": [
                "temperature": 0,
                "thinkingConfig": ["thinkingLevel": "low"],
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "object",
                    "properties": [
                        "box_2d": ["type": "array", "items": ["type": "integer"]],
                        "seenType": ["type": "string", "enum": LitterType.all],
                        "matches": ["type": "boolean"],
                        "description": ["type": "string"],
                    ],
                    "required": ["seenType", "matches", "description"],
                ],
            ],
        ]

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = payload

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                ScanLog.fail("gemini look", "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let parts = (((reply?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }

            var box: [Double]?
            if let b = (json["box_2d"] as? [NSNumber])?.map(\.doubleValue), b.count == 4 {
                let (ymin, xmin, ymax, xmax) = (b[0] / 1000, b[1] / 1000, b[2] / 1000, b[3] / 1000)
                let candidate = [xmin, ymin, xmax - xmin, ymax - ymin].map { min(max($0, 0), 1) }
                if candidate[2] > 0.01, candidate[3] > 0.01 { box = candidate }
            }
            let seen = json["seenType"] as? String ?? "litter"
            var description = (json["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if description.hasSuffix(".") { description.removeLast() }
            if let first = description.first { description = first.uppercased() + description.dropFirst() }
            let sighting = Sighting(box: box, seenType: LitterType.all.contains(seen) ? seen : "litter",
                                    matches: json["matches"] as? Bool ?? false, description: description)
            ScanLog.step("gemini look", since: t0,
                         "\(sighting.seenType) matches=\(sighting.matches) box=\(ScanLog.box(box)) \"\(description)\"")
            return sighting
        } catch {
            ScanLog.fail("gemini look", String(describing: error))
            return nil
        }
    }
}
