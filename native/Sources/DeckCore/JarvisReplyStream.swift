import Foundation

/// Extracts only a respond step's speech. Action arguments are never spoken or executed here.
public struct JarvisReplyStream: Sendable {
  private var raw = ""
  private var decoded = ""
  private var buffered = ""
  public init() {}
  public mutating func append(_ fragment: String) -> [String] {
    raw += fragment
    guard raw.range(of: "\"kind\"\\s*:\\s*\"respond\"",options:.regularExpression) != nil,
      let range = raw.range(of: "\"reply\"\\s*:\\s*\"",options:.regularExpression) else {return []}
    var literal = "\"", escaped = false, closed = false
    for character in raw[range.upperBound...] {
      literal.append(character)
      if character == "\"" && !escaped {closed=true;break}
      if character == "\\" {escaped = !escaped} else {escaped=false}
    }
    var value: String?
    for _ in 0..<14 {
      let candidate = closed ? literal : literal + "\""
      if let result = try? JSONDecoder().decode(String.self,from:Data(candidate.utf8)) {value=result;break}
      guard literal.count>1 else {break}
      literal.removeLast();closed=false
    }
    guard let value, value.hasPrefix(decoded) else {return []}
    buffered += String(value.dropFirst(decoded.count));decoded=value
    var output: [String] = []
    while let end = buffered.indices.first(where: { ".!?\n".contains(buffered[$0]) && buffered.distance(from:buffered.startIndex,to:$0)>=20 }) {
      let after=buffered.index(after:end)
      output.append(String(buffered[..<after]));buffered=String(buffered[after...])
    }
    if closed && !buffered.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {output.append(buffered);buffered=""}
    return output
  }
  public mutating func finish() -> [String] {
    let remaining=buffered.trimmingCharacters(in:.whitespacesAndNewlines);buffered=""
    return remaining.isEmpty ? [] : [remaining]
  }
}
