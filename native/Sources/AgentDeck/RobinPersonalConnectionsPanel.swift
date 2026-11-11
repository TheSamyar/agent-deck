import SwiftUI
import DeckCore

struct RobinPersonalConnectionsPanel: View {
  @State private var accounts:[RobinPersonalAccount]=[]
  @State private var provider="google"
  @State private var label=""
  @State private var clientID=""
  @State private var clientSecret=""
  @State private var selected=Set(RobinPersonalSource.allCases.filter{$0 != .slack})
  @State private var status=""
  @State private var connecting=false
  @State private var allowWrites=false
  @State private var connectionTask:Task<Void,Never>?
  @State private var drafts:[RobinPersonalDraft]=[]
  var body:some View {
    GroupBox("Personal connections · Google + Slack") {
      VStack(alignment:.leading,spacing:10) {
        Text("Connections belong to you. Access is separate from AI subscriptions. Sign-in requires your own registered OAuth application; no maintainer account or credentials are bundled.").font(.caption)
        Picker("Provider",selection:$provider) {Text("Google").tag("google");Text("Slack").tag("slack")}.onChange(of:provider) {_,p in selected=Set(RobinPersonalSource.allCases.filter{$0.provider==p})}
        TextField("Account label",text:$label)
        TextField("OAuth client ID",text:$clientID)
        if provider=="google" {SecureField("Desktop client secret (if required by your Google client)",text:$clientSecret)}
        ForEach(RobinPersonalSource.allCases.filter{$0.provider==provider},id:\.self) {source in
          Toggle(source.rawValue.capitalized,isOn:Binding(get:{selected.contains(source)},set:{if $0 {selected.insert(source)} else {selected.remove(source)}}))
        }
        Text(provider=="google" ? "Create a Google Desktop OAuth client and enable the selected APIs. Google may require consent-screen verification or a test-user entry." : "Create a Slack public-client app with PKCE enabled and user scopes. Register http://localhost:16687/robin/oauth as its redirect. Workspace admin approval may be required.").font(.caption).foregroundStyle(.secondary)
        Link("OAuth app setup",destination:URL(string:provider=="google" ? "https://developers.google.com/identity/protocols/oauth2/native-app" : "https://docs.slack.dev/authentication/using-pkce/")!)
        Toggle("Request write scopes (every external change still requires confirmation)",isOn:$allowWrites)
        Button(connecting ? "Waiting for official sign-in…" : "Connect with official sign-in") {
          connecting=true;status="Complete consent in your browser. No external messages will be sent."
          connectionTask=Task {do {try await RobinPersonalConnections.shared.connect(provider:provider,label:label,clientID:clientID,clientSecret:clientSecret,sources:selected,allowWrites:allowWrites);clientSecret="";accounts=await RobinPersonalConnections.shared.accounts();status="Connected. Enable AI destinations below only when you want to share selected context."} catch {status=error.localizedDescription};connecting=false}
        }.disabled(connecting || clientID.isEmpty || selected.isEmpty)
        if connecting {Button("Cancel sign-in") {connectionTask?.cancel();connectionTask=nil}}
        if !status.isEmpty {Text(status).font(.caption).textSelection(.enabled)}
        ForEach(accounts) {account in
          VStack(alignment:.leading,spacing:5) {
            Text(account.label+" · "+account.provider).font(.headline)
            Text("Enabled: "+account.sources.map(\.rawValue).sorted().joined(separator:", ")).font(.caption)
            ForEach(Array(account.grantedSources ?? account.sources).sorted{$0.rawValue<$1.rawValue},id:\.self) {source in
              Toggle("Use "+source.rawValue,isOn:Binding(get:{account.sources.contains(source)},set:{enabled in var changed=account;if enabled {changed.sources.insert(source)} else {changed.sources.remove(source)};update(changed)})).font(.caption)
            }
            if account.provider=="slack" {
              TextField("Allowed Slack channel names, comma separated",text:Binding(get:{account.slackChannels.joined(separator:", ")},set:{text in var changed=account;changed.slackChannels=text.split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)};update(changed)}))
            }
            ForEach(["chatgpt","claude-subscription","gemini-subscription","cursor-subscription"],id:\.self) {destination in
              Toggle("Allow selected context on "+destination,isOn:Binding(get:{account.destinations.contains(destination)},set:{allowed in var changed=account;if allowed {changed.destinations.insert(destination)} else {changed.destinations.remove(destination)};update(changed)})).font(.caption)
            }
            Button("Disconnect locally") {Task {await RobinPersonalConnections.shared.disconnect(account.id);accounts=await RobinPersonalConnections.shared.accounts()}}
          }
        }
        Button("Refresh prepared changes") {Task {drafts=await RobinPersonalConnections.shared.preparedDrafts()}}
        ForEach(drafts) {draft in
          VStack(alignment:.leading) {
            Text(draft.preview).font(.caption).textSelection(.enabled)
            Button("Confirm this exact external change") {Task {do {status=try await RobinPersonalConnections.shared.executeConfirmedDraft(id:draft.id,revision:draft.revision)} catch {status=error.localizedDescription};drafts=await RobinPersonalConnections.shared.preparedDrafts()}}
          }
        }
        Text("Reads use official APIs. External changes remain previews and require a separate confirmation. Disconnect removes local tokens; revoke the app in Google or Slack settings to revoke server access.").font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth:.infinity,alignment:.leading)
    }.task {accounts=await RobinPersonalConnections.shared.accounts()}
  }
  private func update(_ account:RobinPersonalAccount) {if let index=accounts.firstIndex(where:{$0.id==account.id}) {accounts[index]=account};Task {await RobinPersonalConnections.shared.configure(account)}}
}
