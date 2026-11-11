import AppKit
import ApplicationServices
import DeckCore
import Foundation
import SwiftUI

/// Metadata-only awareness. Detailed application inspection remains an explicit tool.
@MainActor final class RobinContextService: ObservableObject {
  @Published var paused = UserDefaults.standard.bool(forKey:"robin.awareness.paused") { didSet { UserDefaults.standard.set(paused,forKey:"robin.awareness.paused"); if paused { observations=[] } } }
  @Published private(set) var observations:[RobinContextObservation]=[]
  @Published private(set) var status="Waiting for approved context"
  private var activation: NSObjectProtocol?
  private var grants=JarvisGrants()
  private var ignored=Set<String>()
  private var watches:[String:DispatchSourceFileSystemObject]=[:]
  private var handles:[String:Int32]=[:]
  init() {
    activation=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.observeForeground() } }
  }
  deinit { for source in watches.values {source.cancel()}; if let activation {NSWorkspace.shared.notificationCenter.removeObserver(activation)} }
  func forget(_ id:String) {ignored.insert(id);observations.removeAll {$0.id==id}}
  func correct(_ id:String,text:String) {guard let i=observations.firstIndex(where:{$0.id==id}),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return};observations[i].text=String(text.prefix(2000));observations[i].corrected=true;observations[i].observedAt=Date()}
  private func put(_ observation:RobinContextObservation) {
    guard !paused,!ignored.contains(observation.id) else{return}
    if let project=observation.project, !grants.projects.contains(project) {return}
    if observation.source.hasPrefix("app:"),!grants.applications.contains(String(observation.source.dropFirst(4))) {return}
    observations.removeAll {$0.id==observation.id};observations.append(observation)
    if observations.count>50 {observations.removeFirst(observations.count-50)}
  }
  func update(grants:JarvisGrants,snapshot:DeckSnapshot?,tasks:[SupervisedTask]) {
    self.grants=grants
    guard !paused else {status="Awareness paused";return}
    observeForeground()
    let enabled=Set(snapshot?.preferences.enabledAgents ?? [])
    let muted=Set(snapshot?.preferences.mutedProjects ?? [])
    observations.removeAll { observation in
      if let project=observation.project {return !grants.projects.contains(project) || muted.contains(project)}
      if observation.source.hasPrefix("app:") {return !grants.applications.contains(String(observation.source.dropFirst(4)))}
      return false
    }
    let liveTasks=Set(tasks.map {"task:"+$0.id})
    observations.removeAll {$0.id.hasPrefix("task:") && !liveTasks.contains($0.id)}
    for task in tasks where enabled.contains(task.provider.rawValue) && grants.projects.contains(task.cwd) && !muted.contains(task.cwd) {
      put(.init(id:"task:"+task.id,source:"agents",project:task.cwd,text:"\(task.provider.title): \(task.goal). State: \(task.state.rawValue). Evidence: \(String(task.result.prefix(500)))",observedAt:task.updatedAt))
    }
    if let snapshot,let selected=snapshot.sessions[snapshot.selectedSessionId],grants.projects.contains(selected.projectKey),!muted.contains(selected.projectKey) {
      put(.init(id:"selected-project",source:"agents",project:selected.projectKey,text:"Selected workspace: \(selected.workspace). Agent: \(selected.agentName). Reported status: \(selected.status.rawValue)."))
    }
    for root in Array(watches.keys) where !grants.projects.contains(root) {watches[root]?.cancel();watches.removeValue(forKey:root);handles.removeValue(forKey:root)}
    for root in grants.projects where watches[root]==nil {
      let fd=open(root,O_EVTONLY);guard fd>=0 else {continue}
      let source=DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete],queue:.main)
      source.setEventHandler { [weak self] in Task { @MainActor in self?.put(.init(id:"project-change:"+root,source:"filesystem",project:root,text:"Approved project directory changed; inspect relevant files before assuming what changed.")) } }
      source.setCancelHandler {close(fd)}
      watches[root]=source;handles[root]=fd;source.resume()
    }
    status="Aware of \(observations.count) permitted observations"
  }
  func localContext(project:String?) -> String {RobinContextPolicy.context(observations,project:project,cloud:false)}
  func cloudContext(project:String?,provider:String) -> String {
    let values=UserDefaults.standard.dictionary(forKey:"robin.awareness.destinations") as? [String:[String]] ?? [:]
    return RobinContextPolicy.context(observations,project:project,cloud:true,allowedSources:Set(values[provider] ?? []))
  }
  private func observeForeground() {
    guard !paused,let app=NSWorkspace.shared.frontmostApplication,let bundle=app.bundleIdentifier,grants.applications.contains(bundle) else {observations.removeAll {$0.id=="foreground"};return}
    var title=""
    if AXIsProcessTrusted() {
      let root=AXUIElementCreateApplication(app.processIdentifier);var window:CFTypeRef?
      if AXUIElementCopyAttributeValue(root,kAXFocusedWindowAttribute as CFString,&window) == .success,let window,CFGetTypeID(window)==AXUIElementGetTypeID() {
        var value:CFTypeRef?;AXUIElementCopyAttributeValue(unsafeBitCast(window,to:AXUIElement.self),kAXTitleAttribute as CFString,&value);title=String((value as? String ?? "").prefix(300))
      }
    }
    put(.init(id:"foreground",source:"app:"+bundle,text:"Foreground approved application: \(app.localizedName ?? bundle). Window title: \(title.isEmpty ? "unavailable" : title). Title is metadata, not proof of screen contents."))
  }
}
