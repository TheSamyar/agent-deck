import Foundation
public enum RobinReasoningPolicy {
  public static func permitsCloud(text: String) -> Bool {
    let value = text.lowercased()
    if value.range(of: #"(?i)[\"' ]?(?:password|passwd|api[-_ ]?key|token|secret|authorization|aws[-_ ]?(?:access[-_ ]?key|secret[-_ ]?access[-_ ]?key))[\"' ]?\s*[:=]"#, options: .regularExpression) != nil { return false }
    return !["sk-", "gsk_", "ghp_", "bearer ", "password=", "password:", "api key:", "authorization:", "aws_access", "aws_secret", "secret=", "secret:", "token=", "api_key", "private key", ".env"].contains(where: value.contains)
  }
}
