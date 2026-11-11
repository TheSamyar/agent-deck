import Foundation

public enum JarvisFastPath {
  public static func step(for input:String,grants:JarvisGrants) -> JarvisStep? {
    let text=input.trimmingCharacters(in:.whitespacesAndNewlines)
    let plain=text.lowercased().trimmingCharacters(in:.punctuationCharacters)
    if ["stop","cancel","stop what you are doing"].contains(plain) {return .init(kind:.act,action:.stopWork)}
    if ["what are my agents doing","what are all my agents doing","what are my agents working on","what are all my agents working on","check which agents need me","agent status"].contains(plain) {return .init(kind:.act,action:.observe)}
    let apps=["cursor":"com.todesktop.230313mzl4w4u92","chrome":"com.google.Chrome","finder":"com.apple.finder","terminal":"com.apple.Terminal"]
    for (name,id) in apps where plain=="open "+name || plain=="open "+name+" please" {
      return .init(kind:.act,action:.openApplication,arguments:.init(application:id))
    }
    let pattern="(?i)^(?:please\\s+)?(?:read|show)\\s+(?:the file\\s+)?(?:\"([^\"]+)\"|'([^']+)'|(/\\S+))(?:\\s+in\\s+.+)?\\.?$"
    guard let regex=try? NSRegularExpression(pattern:pattern),let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else {return nil}
    for index in 1...3 {
      if let range=Range(match.range(at:index),in:text) {
        return JarvisStep(kind:.act,action:.readFile,arguments:.init(path:String(text[range]))).normalized(grants:grants)
      }
    }
    return nil
  }
}
