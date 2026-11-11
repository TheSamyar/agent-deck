import Foundation
import Darwin
import DeckCore
import SwiftUI

/// Content-free append history, serialized under one lock. Unknown usage is never filled with zero.
final class RobinUsageLedger: @unchecked Sendable {
  static let shared = RobinUsageLedger()
  private let lock=NSLock()
  private let file: URL
  private var records: [RobinUsageRecord]=[]
  private var error: String?
  private var gapCount=0
  private var gapsDirectory: URL { file.deletingLastPathComponent().appendingPathComponent("CoverageGaps") }
  var storageError: String? { lock.withLock { error ?? (gapCount>0 ? "Usage coverage incomplete: \(gapCount) failed recording operations remain marked. Provider costs may be missing." : nil) } }
  init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Agent Deck/Usage/robin-model-usage.json")) {
    self.file=file
    _ = snapshot()
  }
  func snapshot() -> [RobinUsageRecord] { lock.withLock {
    withDiskLock { }; return records
  } }
  func record(_ record: RobinUsageRecord) { lock.withLock {
    withDiskLock(gapID: record.id) {
      guard !records.contains(where: { $0.id==record.id }) else { return }
      records.append(record); persist(gapID: record.id)
    }
  } }
  func annotate(id: UUID, structuredValid: Bool, benchmarkRunID: String, caseID: Int) { lock.withLock {
    withDiskLock(gapID: id) {
      guard let index=records.firstIndex(where: { $0.id==id }) else { return }
      records[index].structuredValid=structuredValid; records[index].benchmarkRunID=benchmarkRunID; records[index].benchmarkCaseID=caseID; records[index].benchmarkSuiteVersion="robin-planning-v1"; persist(gapID: id)
    }
  } }
  private func noteGap(_ id: UUID?, reason: String) {
    guard let id else { return }
    gapCount=max(1,gapCount)
    let value=["id":id.uuidString,"timestamp":ISO8601DateFormatter().string(from:Date()),"reason":reason]
    do {
      try FileManager.default.createDirectory(at:gapsDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
      let target=gapsDirectory.appendingPathComponent(id.uuidString+".json")
      try JSONSerialization.data(withJSONObject:value).write(to:target,options:.atomic)
      try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
    } catch { /* The sticky in-process error remains when storage itself is unavailable. */ }
  }
  private func withDiskLock(gapID: UUID? = nil, _ body: () -> Void) {
    do { try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
    catch { self.error="Usage folder is unavailable. Provider billing may include unrecorded requests."; noteGap(gapID,reason:"folderUnavailable"); return }
    let descriptor=Darwin.open(file.appendingPathExtension("lock").path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
    guard descriptor>=0 else { error="Could not lock usage history."; noteGap(gapID,reason:"lockUnavailable"); return }
    defer { Darwin.close(descriptor) }
    var acquired=false
    for _ in 0..<20 {
      if flock(descriptor,LOCK_EX|LOCK_NB)==0 { acquired=true; break }
      usleep(10_000)
    }
    guard acquired else { error="Usage history is busy; this attempt may be unrecorded."; noteGap(gapID,reason:"lockTimeout"); return }
    defer { flock(descriptor,LOCK_UN) }
    do {
      if FileManager.default.fileExists(atPath:file.path) {
        let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        records=try decoder.decode([RobinUsageRecord].self,from:Data(contentsOf:file))
      } else { records=[] }
    } catch { self.error="Usage history could not be read; existing data was preserved."; noteGap(gapID,reason:"historyUnreadable"); return }
    gapCount=(try? FileManager.default.contentsOfDirectory(at:gapsDirectory,includingPropertiesForKeys:nil).filter { $0.pathExtension=="json" }.count) ?? gapCount
    error=nil; body()
  }
  private func persist(gapID: UUID) {
    do {
      let encoder=JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(records).write(to:file,options:.atomic)
      try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
      error=nil
    } catch { self.error="Usage history could not be saved. Provider billing may include unrecorded requests."; noteGap(gapID,reason:"writeFailed") }
  }
}

@MainActor final class RobinComparisonStore: ObservableObject {
  @Published private(set) var records: [RobinUsageRecord]=[]
  @Published private(set) var storageError: String?
  @Published var workload = RobinWorkload()
  private let ledger: RobinUsageLedger
  init(ledger: RobinUsageLedger = .shared) { self.ledger=ledger; refresh() }
  func refresh() { records=ledger.snapshot(); storageError=ledger.storageError }
  var monthRecords: [RobinUsageRecord] { RobinUsageMath.monthRecords(records) }
  var estimatedMonthCost: Double { monthRecords.compactMap(RobinPricing.estimate).reduce(0,+) }
  var unknownCostAttempts: Int { monthRecords.filter { RobinPricing.estimate($0)==nil }.count }
}

struct RobinComparisonPanel: View {
  @ObservedObject var store: RobinComparisonStore
  var body: some View {
    GroupBox("Performance + monthly price") {
      VStack(alignment:.leading,spacing:8) {
        Text("Alfred reasoning-model usage only").font(.headline)
        Text("This UTC month: \(store.monthRecords.count) recorded attempts · $\(store.estimatedMonthCost,specifier:"%.4f") known-token cost estimate · \(store.unknownCostAttempts) unknown-cost attempts.")
          .font(.caption).textSelection(.enabled)
        Text("Partial coverage from installation. Not your provider invoice. Voice, tools, legacy chat and other apps are excluded. Missing usage is unknown, not free.").font(.caption).foregroundStyle(.secondary)
        if let error=store.storageError { Text(error).font(.caption).foregroundStyle(.orange) }
        Link("Open performance and 30-day cost dashboard",destination:URL(string:"http://127.0.0.1:64783")!)
      }.frame(maxWidth:.infinity,alignment:.leading)
    }.onAppear { store.refresh() }
  }
}
