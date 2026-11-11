import Foundation
import SwiftUI

@MainActor final class AlfredWakeSetup: ObservableObject {
  @Published private(set) var installing = false
  @Published private(set) var status = "Optional experimental wake runtime. The Listen button works without it."
  private var process: Process?
  init() {
    if (try? AlfredWakeRuntime.checkAssets()) != nil {
      status = "Experimental Alfred wake runtime installed · acoustic validation pending."
    }
  }
  func install() {
    guard !installing else { return }
    installing = true
    status = "Preparing the optional wake runtime…"
    let task = Process(), output = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    task.arguments = [AlfredWakeRuntime.resourceDirectory.appendingPathComponent("setup.py").path]
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    do {
      try task.run(); process = task
      Task.detached { [weak self] in
        var pending = Data()
        while true {
          let chunk = output.fileHandleForReading.availableData
          if chunk.isEmpty { break }
          pending.append(chunk)
          if pending.count > 65536 { pending = Data(pending.suffix(65536)) }
          while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end]); pending.removeSubrange(...end)
            await self?.event(line)
          }
        }
        task.waitUntilExit()
        await self?.finished(task.terminationStatus)
      }
    } catch { installing = false; status = error.localizedDescription }
  }
  private func event(_ data: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = json["message"] as? String else { return }
    status = message
  }
  private func finished(_ code: Int32) {
    process = nil; installing = false
    if code == 0 {
      status = "Experimental Alfred wake runtime installed · acoustic validation pending. Hands-free has not been enabled."
    } else if !status.lowercased().contains("error") {
      status += " Installation did not complete. Existing runtime was preserved; manual Listen still works."
    }
  }
}

struct AlfredWakeSetupView: View {
  @StateObject private var setup = AlfredWakeSetup()
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Dedicated wake detection · experimental").font(.caption.bold())
      Text("Explicit setup downloads an isolated Python 3.11 runtime and checksum-verified Alfred model. No microphone is opened during setup. This model's recognition accuracy has not been certified.")
        .font(.caption).foregroundStyle(.secondary)
      Button(setup.installing ? "Installing wake runtime…" : "Install / repair wake runtime") { setup.install() }
        .disabled(setup.installing)
      if setup.installing { ProgressView() }
      Text(setup.status).font(.caption).textSelection(.enabled)
    }
  }
}
