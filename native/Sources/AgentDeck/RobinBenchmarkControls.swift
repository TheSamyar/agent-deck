import SwiftUI
import DeckCore

@MainActor final class RobinBenchmarkController: ObservableObject {
  @Published private(set) var running = false
  @Published private(set) var status = "No benchmark run yet. Missing credentials are skipped; no substitute models."
  let runner = RobinBenchmarkRunner()
  private var task: Task<Void,Never>?
  func cancel() { task?.cancel(); runner.cancel(); status = "Cancelling; any already-sent request may still be billed." }
  func start(configuration: SupervisorConfiguration, selected: String, allConfigured: Bool, paidConsent: Bool, budgetUSD: Double, full: Bool) {
    guard !running else { return }
    running = true
    task = Task { [weak self] in
      guard let self else { return }; defer { self.running = false }
      await self.execute(configuration: configuration, selected: selected, allConfigured: allConfigured, paidConsent: paidConsent, budgetUSD: budgetUSD, full: full)
    }
  }
  func execute(configuration: SupervisorConfiguration, selected: String, allConfigured: Bool, paidConsent: Bool, budgetUSD: Double, full: Bool) async {
    guard budgetUSD.isFinite, budgetUSD >= 0 else { status = "Enter a valid nonnegative budget."; return }
    let models = allConfigured ? RobinModelCatalog.all : RobinModelCatalog.all.filter { $0.id == selected }
    let cases = full ? nil : [1,6,11,16,21,26]
    var remaining = budgetUSD
    var reports: [String] = []
    for model in models {
      guard !Task.isCancelled else { status = "Cancelled. Completed attempts remain in the ledger."; return }
      if RobinSubscriptionConnection.contains(model.providerID) {
        reports.append(model.name + ": excluded from API-token-cap benchmark because plan/model output limits differ. Normal subscription requests appear in recorded usage; no benchmark quota consumed."); continue
      }
      if model.providerID != "local" {
        guard configuration.robinSubscriptionOnly != true else { reports.append(model.name + ": skipped (subscription-only mode blocks APIs)"); continue }
        guard paidConsent, remaining > 0 else { reports.append(model.name + ": skipped (no cloud run consent/budget)"); continue }
        guard RobinProviderKeychain.hasCredential(providerID: model.providerID) else { reports.append(model.name + ": not configured"); continue }
        if model.providerID == "cloudflare", (configuration.robinCloudflareAccountID ?? "").isEmpty { reports.append("Cloudflare: account ID missing"); continue }
      }
      status = "Comparing " + model.name + ". No proposed tools will execute."
      await runner.run(modelID: model.id, paidConsent: paidConsent, budgetUSD: remaining, caseIDs: cases) { test, runID, limit in
        let instruction = RobinBenchmarkRunner.fixtureInstruction + "\nReturn JSON matching this schema: " + String(decoding: try JSONSerialization.data(withJSONObject: JarvisStep.schema), as: UTF8.self)
        let result = try await RobinProviderClient.shared.complete(modelID: model.id,
          messages: [["role":"system","content":instruction],["role":"user","content":test.request]], schema: JarvisStep.schema,
          cloudflareAccountID: configuration.robinCloudflareAccountID ?? "", selectedModelID: model.id,
          benchmarkRunID: runID, benchmarkCaseID: test.id, maxOutputTokens: limit)
        return RobinBenchmarkReply(text: result.text, usageRecordID: result.usageRecordID)
      }
      reports.append(model.name + ": " + runner.progress)
      remaining = max(0, remaining - runner.spentEstimateUSD)
      if model.providerID != "local", runner.hadUnknownUsage {
        reports.append("Stopped all remaining cloud tests because usage is unknown. Check the provider invoice."); break
      }
    }
    status = reports.isEmpty ? "No models selected." : reports.joined(separator: "\n")
  }
}

struct RobinBenchmarkControls: View {
  @ObservedObject var store: SupervisorStore
  @ObservedObject private var controller: RobinBenchmarkController
  @ObservedObject private var runner: RobinBenchmarkRunner
  @State private var cloudConsent = false
  @State private var budget = "0"
  @State private var full = false
  init(store: SupervisorStore) { self.store = store; controller = store.modelBenchmark; runner = store.modelBenchmark.runner }
  var body: some View {
    GroupBox("Compare performance · same tasks") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Synthetic planning only: same prompts and output limit, no tools executed, no fallback. Valid JSON is not proof of completed work.").font(.caption)
        Toggle("Full 30-case suite (otherwise 6 cases)", isOn: $full).disabled(controller.running)
        Toggle("I authorize provider usage charges for this benchmark", isOn: $cloudConsent).disabled(controller.running)
        HStack { Text("Whole-run estimate budget, USD"); TextField("0", text: $budget).frame(width: 90).disabled(controller.running) }
        Text("Default $0 runs local only. A positive budget plus consent is required for cloud tests, even free hosts whose quota may be shared. This app threshold is not a provider billing cap.").font(.caption).foregroundStyle(.secondary)
        HStack {
          Button("Test selected brain") { run(all: false) }.disabled(controller.running)
          Button("Compare all configured") { run(all: true) }.disabled(controller.running)
          if controller.running { Button("Cancel") { controller.cancel() } }
        }
        Text(controller.running ? runner.progress : controller.status).font(.caption).textSelection(.enabled)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func run(all: Bool) {
    controller.start(configuration: store.configuration, selected: store.selectedReasoningModelID, allConfigured: all,
      paidConsent: cloudConsent, budgetUSD: Double(budget) ?? -1, full: full)
  }
}
