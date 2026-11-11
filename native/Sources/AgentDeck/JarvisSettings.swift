import AppKit
import DeckCore
import SwiftUI

struct JarvisSettings: View {
  @ObservedObject var runtime: JarvisRuntime
  var body: some View {
    GroupBox("Alfred permissions") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Only apps and projects you approve here can be changed. The model cannot approve access.").font(.caption)
        ForEach([("Cursor","com.todesktop.230313mzl4w4u92"),("Chrome","com.google.Chrome"),("Finder","com.apple.finder"),("Terminal","com.apple.Terminal")], id: \.1) { name,id in
          Toggle(name,isOn:Binding(get:{runtime.grants.applications.contains(id)},set:{ enabled in
            if enabled { runtime.grants.applications.insert(id) } else { runtime.grants.applications.remove(id) };runtime.save()
          }))
        }
        Button("Approve project folder…") {
          let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false
          if panel.runModal() == .OK, let url=panel.url { runtime.grants.projects.insert(url.resolvingSymlinksInPath().path);runtime.save() }
        }
        ForEach(runtime.grants.projects.sorted(),id:\.self) { project in
          HStack { Text(project).font(.caption).textSelection(.enabled);Spacer();Button("Remove") {runtime.grants.projects.remove(project);runtime.save()} }
          Button("Approve this project's test command") {runtime.approveTests(project)}
        }
        ForEach(runtime.commands) {command in Text(command.executable + " " + command.arguments.joined(separator:" ")).font(.caption).textSelection(.enabled)}
        Toggle("Talk me through actions",isOn:Binding(get:{runtime.talkThrough},set:{runtime.talkThrough=$0;runtime.save()}))
        Button("Register Chrome bridge…") {runtime.installBrowserBridge()}
        Button("Import sites approved in Chrome") {Task {await runtime.importBrowserSites()}}
        Text(runtime.browserSetup).font(.caption).textSelection(.enabled)
        Text(runtime.talkThrough ? "Speaks major actions while working." : "Quiet mode: reports completion or a blocker.").font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth:.infinity,alignment:.leading)
    }
  }
}
