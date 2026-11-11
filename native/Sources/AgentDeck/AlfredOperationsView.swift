import SwiftUI
import DeckCore

struct AlfredOperationsView: View {
  @StateObject private var client = AlfredOperationsClient()
  @State private var filter = "Open"
  private var visibleCases: [AlfredOperationsCase] {
    client.cases.filter { filter == "All" || (filter == "Resolved" ? $0.status == "resolved" : $0.status != "resolved") }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Operations").font(.title2.bold())
        Spacer()
        if client.loading { Button("Stop refresh") { client.cancelRefresh() } }
        else { Button("Refresh") { Task { await client.refresh() } } }
        if let url = client.serverURL { Link("Open Alfred server", destination: url.appendingPathComponent("operations")) }
      }
      Text(client.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if let date = client.lastRefreshed { Text("Snapshot: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
      Text("Your Alfred server stores cases and diagnostic observations. Stopping this refresh does not pause remote work; manage worker access in your Alfred server. Hub is an optional source.")
        .font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("Alfred server connection") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Sign in to your own Alfred server, create a read-only native device connection, and paste its credential here. It is stored only in macOS Keychain. No Hub account or browser session is required.").font(.caption)
          TextField("Alfred server HTTPS origin", text: $client.serverOrigin).disabled(client.loading)
          SecureField("Native device credential (ald_…)", text: $client.deviceCredential).disabled(client.loading)
          HStack {
            if let url = client.serverURL { Link("Sign in / manage devices", destination: url) }
            Button("Save and connect") { Task { await client.connect() } }.disabled(client.loading)
            Button("Disconnect locally") { client.disconnect() }
          }
        }.padding(.top, 6)
      }
      Picker("Cases", selection: $filter) { Text("Open").tag("Open"); Text("Resolved").tag("Resolved"); Text("All").tag("All") }.pickerStyle(.segmented)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if visibleCases.isEmpty {
            Text(client.lastRefreshed == nil ? "Connect Alfred and refresh to see the real queue. No cases have been loaded." : "No cases in this snapshot match the selected filter.")
              .foregroundStyle(.secondary).padding()
          }
          ForEach(visibleCases) { item in
            GroupBox {
              VStack(alignment: .leading, spacing: 6) {
                HStack { Text(item.title).font(.headline); Spacer(); Text(item.displayStatus).font(.caption.bold()) }
                if !item.summary.isEmpty { Text(item.summary).font(.callout).textSelection(.enabled) }
                HStack {
                  if let id = item.businessId { Text("Client #\(id)") }
                  if let id = item.linkedTaskId { Text("Hub task #\(id)") }
                  Text("Revision \(item.revision)")
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(Array(item.sourceRefs.enumerated()), id: \.offset) { _, source in
                  if let url = source.url { Link("Source: \(source.provider)", destination: url).font(.caption) }
                }
                if let origin = client.snapshotOrigin, let url = item.caseURL(origin: origin) { Link("Review diagnosis and observations", destination: url).font(.caption.bold()) }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
    }.padding(8)
  }
}
