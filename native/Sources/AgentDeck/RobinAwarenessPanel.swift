import SwiftUI
import DeckCore

struct RobinAwarenessPanel: View {
  @ObservedObject var awareness: RobinContextService
  @State private var destination="chatgpt"
  @State private var grantRevision=0
  var body: some View {
    GroupBox("What Alfred knows") {
      VStack(alignment:.leading,spacing:12) {
        Toggle("Pause workspace awareness",isOn:$awareness.paused)
        Text(awareness.status).font(.caption).foregroundStyle(.secondary)
        Text("Only approved apps and projects are observed. Personal accounts and cloud sharing have separate controls.").font(.caption)
        Picker("Share selected context with",selection:$destination) {
          ForEach(RobinModelCatalog.all.filter { RobinModelCatalog.subscriptionProviderIDs.contains($0.providerID) },id:\.id) {Text($0.name).tag($0.providerID)}
        }
        ForEach(Array(Set(awareness.observations.map(\.source)).union(["personal-memory"])).sorted(),id:\.self) { source in
          Toggle("Allow " + source + " on " + destination,isOn:Binding(get:{
            _ = grantRevision
            let map=UserDefaults.standard.dictionary(forKey:"robin.awareness.destinations") as? [String:[String]] ?? [:]
            return map[destination]?.contains(source) == true
          },set:{enabled in
            var map=UserDefaults.standard.dictionary(forKey:"robin.awareness.destinations") as? [String:[String]] ?? [:]
            var values=map[destination] ?? [];values.removeAll {$0==source};if enabled {values.append(source)};map[destination]=values
            UserDefaults.standard.set(map,forKey:"robin.awareness.destinations");grantRevision += 1
          }))
        }
        ForEach(awareness.observations,id:\.id) { observation in
          RobinAwarenessRow(awareness:awareness,id:observation.id,source:observation.source,text:observation.text,date:observation.observedAt)
        }
      }.frame(maxWidth:.infinity,alignment:.leading)
    }
  }
}
private struct RobinAwarenessRow: View {
  @ObservedObject var awareness:RobinContextService
  let id:String; let source:String; let text:String; let date:Date
  @State private var editing=false
  @State private var correction=""
  var body: some View {
    VStack(alignment:.leading,spacing:5) {
      HStack {Text(source).font(.caption.bold());Text(date,style:.relative).font(.caption).foregroundStyle(.secondary);Spacer();Button("Correct"){correction=text;editing=true};Button("Forget"){awareness.forget(id)}}
      if editing {TextField("Correction",text:$correction);Button("Save correction"){awareness.correct(id,text:correction);editing=false}}
      else {Text(text).font(.callout).textSelection(.enabled)}
    }.padding(10).background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
  }
}
