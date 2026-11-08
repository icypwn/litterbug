import UIKit

/// Checks a pickup photo with Gemini (same model the drone uses to classify litter):
/// is there litter in it, and is it the kind the drone said was here?
enum PickupVerifier {
    // Flash-Lite: ~1 s vs ~4.5–7.7 s. Only the fallback now — the scan's LitterLocator.look normally answers this.
    static let model = "gemini-3.5-flash-lite"

    struct Verdict: Decodable {
        /// True when the photo shows litter of the expected type (any litter, if the pin is plain "litter").
        let matches: Bool
        /// What Gemini thinks it is, one of LitterType.all.
        let seenType: String
        let reason: String
    }

    enum Failure: Error { case noKey, network, unreadable }

    static func verify(photo: UIImage, expectedType: String) async throws -> Verdict {
        guard !Secrets.geminiKey.isEmpty else { throw Failure.noKey }
        guard let jpeg = photo.downscaled(maxSide: 1024).jpegData(compressionQuality: 0.7) else { throw Failure.unreadable }

        let expected = expectedType == "litter"
            ? "any piece of litter"
            : "a \(LitterType.displayName(expectedType).lowercased()) (category \"\(expectedType)\")"
        let prompt = """
        Someone says they just picked up litter and took this photo of it (in their hand, a bag, or on the ground).
        A drone spotted \(expected) at this spot.

        seenType: which ONE category the main piece of litter in the photo is:
          bottle (plastic or glass drink bottle), can (metal drink or food can), bag (plastic or paper bag),
          wrapper (snack, candy or food wrapper), cup (disposable cup, coffee cup, lid), litter (anything else).
        matches: true only if the photo really shows a piece of litter AND it is \(expected).
          False for photos of nothing, people, pets, screens, or clean objects that aren't litter.
        reason: at most 10 words.
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
                        "matches": ["type": "boolean"],
                        "seenType": ["type": "string", "enum": LitterType.all],
                        "reason": ["type": "string"],
                    ],
                    "required": ["matches", "seenType", "reason"],
                ],
            ],
        ]

        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.geminiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.network }

        struct Reply: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }
        let text = (try? JSONDecoder().decode(Reply.self, from: data))?
            .candidates?.first?.content?.parts?.compactMap(\.text).joined() ?? ""
        guard let verdict = try? JSONDecoder().decode(Verdict.self, from: Data(text.utf8)) else { throw Failure.unreadable }
        return verdict
    }
}
