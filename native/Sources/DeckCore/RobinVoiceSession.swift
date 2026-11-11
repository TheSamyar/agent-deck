import Foundation

/// Turn policy independent of hardware, shared by the voice session and fixture tests.
public enum RobinVoiceSession {
  public static func endOfTurnDelay(for transcript: String) -> Double {
    let words = transcript.lowercased().split(whereSeparator: { $0.isWhitespace })
    guard let last = words.last else { return 2.0 }
    // Leave room for corrections and incomplete clauses instead of cutting off at 1.2s.
    if ["and", "but", "because", "or", "then", "the", "a", "to", "with", "actually"].contains(String(last)) { return 2.4 }
    return words.count < 4 ? 1.8 : 1.5
  }
  public static func shouldInterrupt(speaking: Bool, echoControlled: Bool, sustainedSpeech: Bool) -> Bool {
    speaking && echoControlled && sustainedSpeech
  }
}
