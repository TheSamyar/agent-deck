import Foundation

/// Shared billing boundary for app-started managed sessions, including Codex app-server.
public enum ManagedSubscriptionPolicy {
  public static func enabled(configurationData: Data?) -> Bool {
    guard let configurationData else { return false }
    guard let value = try? JSONDecoder().decode(SupervisorConfiguration.self, from: configurationData) else { return true }
    return value.robinSubscriptionOnly == true
  }
  public static func environment(_ inherited: [String: String]) -> [String: String] {
    let allowed = Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME"])
    return inherited.filter { allowed.contains($0.key) }
  }
  public static var codexAppServerArguments: [String] {
    ["-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\"", "-c", "model_providers={}", "app-server"]
  }
  public static func isChatGPTAccount(_ response: [String: Any]) -> Bool {
    (response["account"] as? [String: Any])?["type"] as? String == "chatgpt"
  }
  public static var codexThreadConfiguration: [String: Any] {
    ["modelProvider": "openai", "approvalPolicy": "on-request", "sandbox": "workspace-write",
     "config": ["forced_login_method": "chatgpt", "model_provider": "openai", "model_providers": [:]]]
  }
}
