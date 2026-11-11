import Foundation

/// Timestamp-only endpointing policy. Audio/transcripts stay with the capture owner.
public struct AlfredTurnPolicy: Sendable {
  public private(set) var transcript = ""
  private var lastTranscriptAt: TimeInterval?
  private var lastSpeechAt: TimeInterval?
  private var speechActive = false
  public init() {}
  public mutating func speech(active: Bool, at time: TimeInterval) {
    speechActive = active
    if active { lastSpeechAt = time }
  }
  public mutating func update(transcript: String, at time: TimeInterval) {
    guard self.transcript != transcript else { return }
    self.transcript = transcript
    lastTranscriptAt = time
  }
  public var silenceDelay: TimeInterval {
    let words = transcript.lowercased().split(whereSeparator: { $0.isWhitespace })
    guard let last = words.last else { return 1.8 }
    let tail = String(last).trimmingCharacters(in: .punctuationCharacters)
    return words.count < 4 || ["and", "but", "because", "or", "then", "the", "a", "to", "with", "actually"].contains(tail) ? 1.8 : 0.9
  }
  public func shouldFinish(at time: TimeInterval) -> Bool {
    guard !speechActive, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let changed = lastTranscriptAt else { return false }
    return time - changed >= 0.35 && time - (lastSpeechAt ?? changed) >= silenceDelay
  }
}
