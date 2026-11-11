import Foundation
import AppKit

public enum TileArtwork {
  public static func escape(_ text: String) -> String {
    text.unicodeScalars.filter {
      let value = $0.value
      return [0x9, 0xA, 0xD].contains(value) || (0x20...0xD7FF).contains(value)
        || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value)
    }
      .map(String.init).joined().replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
  // Conservative glyph widths keep labels legible on small hardware displays.
  public static func wrap(_ text: String) -> [String] {
    func width(_ c: Character) -> Double {
      if c.isWhitespace { return 0.3 }
      if "ilI.,:!|'".contains(c) { return 0.28 }
      if "MW@".contains(c) || c.unicodeScalars.contains(where: { $0.value > 0x2FF }) { return 1 }
      return 0.58
    }
    var remaining = Array(text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
    var lines: [String] = []
    for line in 0..<2 {
      var count = 0
      var used = 0.0
      let budget = line == 1 ? 5.8 : 6.4
      while count < remaining.count && used + width(remaining[count]) <= budget {
        used += width(remaining[count]); count += 1
      }
      if count < remaining.count, let space = remaining.prefix(count).lastIndex(of: " "), space > 0 {
        count = space
      }
      lines.append(String(remaining.prefix(count)))
      remaining.removeFirst(count)
      while remaining.first == " " { remaining.removeFirst() }
      if line == 1 && !remaining.isEmpty { lines[1] += "…" }
    }
    return lines
  }
  private static func caption(_ text: String) -> String {
    let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let font = NSFont(name: "HelveticaNeue-Medium", size: 7.5) ?? NSFont.systemFont(ofSize: 7.5, weight: .medium)
    func fits(_ value: String) -> Bool {
      (value as NSString).size(withAttributes: [.font: font]).width <= 88
    }
    guard !fits(normalized) else { return escape(normalized) }
    var prefix = ""
    for character in normalized {
      let next = prefix + String(character)
      guard fits(next + "…") else { break }
      prefix = next
    }
    return escape(prefix + "…")
  }
  public static func render(_ tile: TileSnapshot) -> String {
    var color = "#AAB2BF"
    var symbol = "–"
    switch tile.status {
    case "WAITING": (color, symbol) = ("#F2BD63", "!")
    case "DONE": (color, symbol) = ("#86D6AB", "✓")
    case "ERROR", "DISCONNECTED": (color, symbol) = ("#F09B9B", "×")
    case "WORKING": (color, symbol) = ("#A4C8FF", "•")
    default:
      color = "#AAB2BF"
      switch tile.action {
      case "next": symbol = "→"
      case "previous", "overview": symbol = "←"
      case "attention": symbol = "!"
      case "dashboard", "focus": symbol = "↗"
      case "stop": symbol = "■"
      default: symbol = "–"
      }
    }
    let lines = wrap(tile.label)
    let twoLines = !lines[1].isEmpty
    let opacity = tile.enabled ? "1" : "0.58"
    let detail = tile.requiresHold ? "HOLD TO CONFIRM" : tile.detail
    let border = tile.status == "WAITING" && tile.enabled ? "#866334" : "#353D49"
    return """
      <svg xmlns="http://www.w3.org/2000/svg" width="{{size}}" height="{{size}}" viewBox="0 0 100 100">
      <rect width="100" height="100" rx="13" fill="#12171E"/>
      <rect x="0.6" y="0.6" width="98.8" height="98.8" rx="12.4" fill="none" stroke="\(border)" stroke-width="1.2"/>
      <g opacity="\(opacity)" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" text-anchor="middle">
      <rect x="39" y="6" width="22" height="2" rx="1" fill="\(color)"/>
      <text x="50" y="20" fill="#B8C1CE" font-size="7.5" font-weight="500">\(caption(tile.sublabel.uppercased()))</text>
      <text x="50" y="\(twoLines ? 43 : 50)" fill="#F5F7FA" font-size="12.5" font-weight="600">\(escape(lines[0]))</text>
      <text x="50" y="59" fill="#F5F7FA" font-size="12.5" font-weight="600">\(escape(lines[1]))</text>
      <text x="50" y="78" fill="\(color)" font-size="14" font-weight="600">\(symbol)</text>
      <text x="50" y="92" fill="\(color)" font-size="7.5" font-weight="500">\(caption(detail))</text>
      </g></svg>
      """
  }
}
