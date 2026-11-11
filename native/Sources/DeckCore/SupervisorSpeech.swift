import Foundation

public enum SupervisorSpeech {
  public static let voices = ["af_heart", "af_bella", "am_michael", "bf_emma"]
  public static func prepared(_ text: String) -> String {
    // Emoji are grapheme clusters: remove the whole sequence (skin tones, flags,
    // keycaps, variation selectors, and joined families), preserving plain digits.
    let plain = text.map { character -> String in
      let emoji = character.unicodeScalars.contains {
        ($0.properties.isEmoji && $0.value > 0x7f) || [0xfe0f, 0x20e3, 0x200d].contains($0.value)
      }
      return emoji ? " " : String(character)
    }.joined()
    var value = plain.replacingOccurrences(of: "```[\\s\\S]*?```", with: " There is a code example in the app. ", options: .regularExpression)
    value = value.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
    value = value.replacingOccurrences(of: "(?m)^\\s*#{1,6}\\s+", with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: "(?m)^\\s*[-•]\\s+", with: "", options: .regularExpression)
    value = value.replacingOccurrences(of: "[^\\S\\n]+", with: " ", options: .regularExpression)
    return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16000))
  }
}
