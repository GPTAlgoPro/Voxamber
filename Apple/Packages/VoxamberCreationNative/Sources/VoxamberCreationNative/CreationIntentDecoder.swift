import Foundation
import CreationCore

enum CreationIntentDecoder {
    static let systemPrompt = """
    Translate the user's visual idea into concise English. Preserve the subjects, counts, relationships, colors, materials and explicit exclusions. Do not replace objects, invent features, write geometry or explain.
    Return only {"positivePrompt":"English translation"}. Use printable English ASCII, 1-512 characters. There are no other output fields.
    """

    static let schema = """
    {"type":"object","properties":{"positivePrompt":{"type":"string","pattern":"^[ -~]{1,512}$"}},"required":["positivePrompt"],"additionalProperties":false}
    """

    static func decode(_ response: String, sourcePrompt: String) throws -> CreationIntent {
        guard response.utf8.count <= 4096,
              let object = try? StrictJSONObject.decode(response, maximumBytes: 4096),
              Set(object.keys) == ["positivePrompt"],
              let positive = object["positivePrompt"] as? String else {
            throw CreationError.invalidIntent
        }
        let firstLine = sourcePrompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = String(firstLine.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(40))
        let intent = CreationIntent(title: title, positivePrompt: positive, negativePrompt: "")
        guard (1...40).contains(intent.title.count),
              !intent.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !intent.positivePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              intent.positivePrompt.count <= 512, intent.negativePrompt.isEmpty,
              intent.positivePrompt.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }),
              ![intent.title, intent.positivePrompt, intent.negativePrompt].contains(where: {
                  $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else { throw CreationError.invalidIntent }
        return intent
    }
}
