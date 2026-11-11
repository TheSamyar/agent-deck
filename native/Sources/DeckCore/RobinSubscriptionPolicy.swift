import Foundation

public enum RobinSubscriptionPolicy {
  public static let disabledFeatures = ["shell_tool","unified_exec","apps","browser_use","computer_use","hooks","plugins","multi_agent","multi_agent_v2","view_image","sleep_tool","skill_search","skill_mcp_dependency_install","remote_plugin","plugin_sharing","plugin_discovery_prefetch","browser_use_external","browser_use_full_cdp_access","in_app_browser","code_mode","code_mode_host","memories","image_generation","shell_snapshot","shell_snapshot_v2"]
  public static func arguments(schema: String, output: String) -> [String] {
    var result = ["-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\"", "-c", "web_search=\"disabled\"", "-c", "mcp_servers={}", "-c", "apps._default.enabled=false", "-c", "project_doc_max_bytes=0", "-c", "approval_policy=\"never\""]
    for feature in disabledFeatures { result += ["--disable", feature] }
    result += ["--enable", "skip_host_skill_discovery"]
    return result + ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "--output-schema", schema, "--output-last-message", output, "--json", "-"]
  }
  public static func unexpectedToolEvent(_ event: [String:Any]) -> Bool {
    guard let item=event["item"] as? [String:Any],let kind=item["type"] as? String else {return false}
    return !["agent_message", "reasoning", "error"].contains(kind)
  }
  public static func usage(_ event: [String:Any]) -> RobinProviderUsage {
    guard let value=event["usage"] as? [String:Any] else {return .init()}
    func count(_ key:String)->Int? {
      guard let n=value[key] as? NSNumber, String(cString:n.objCType) != "c", n.doubleValue.isFinite, let i=Int(exactly:n.doubleValue),i>=0 else {return nil};return i
    }
    guard let input=count("input_tokens"),let output=count("output_tokens") else {return .init()}
    let cached=count("cached_input_tokens")
    guard cached.map({$0<=input}) != false else {return .init()}
    return .init(inputTokens:input,outputTokens:output,cachedInputTokens:cached)
  }

}
