import AppKit
import DeckCore
import SwiftUI
import WebKit

struct KeypadButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.overlay {
      RoundedRectangle(cornerRadius: 15)
        .fill(.white.opacity(configuration.isPressed ? 0.18 : 0))
    }
  }
}

/// Action identity is part of rendering identity even when two layouts look identical.
struct KeypadDisplayState: Equatable {
  let tiles: [TileSnapshot]
  let revision: Int?
  let instanceID: String?
  let demo: Bool
}

/// Inert artwork layer: all input stays in accessible native buttons above it.
struct KeypadArtworkView: NSViewRepresentable {
  let layout: KeypadDisplayState
  let keySize: CGFloat
  let gap: CGFloat
  @Binding var rendered: KeypadDisplayState?
  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.setValue(false, forKey: "drawsBackground")
    view.navigationDelegate = context.coordinator
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {
    let size = Int(keySize)
    let artwork = layout.tiles.map {
      ($0.svg.isEmpty ? TileArtwork.render($0) : $0.svg)
        .replacingOccurrences(of: "{{size}}", with: String(size))
    }.joined()
    let html = """
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>html,body{margin:0;padding:0;overflow:hidden;background:transparent}body{display:grid;grid-template-columns:repeat(3,\(size)px);gap:\(Int(gap))px}svg{display:block}</style>
      \(artwork)
      """
    let coordinator = context.coordinator
    coordinator.acknowledgement = $rendered
    guard coordinator.requested != layout else { return }
    coordinator.requested = layout
    coordinator.navigation = view.loadHTMLString(html, baseURL: nil)
  }
  final class Coordinator: NSObject, WKNavigationDelegate {
    var requested: KeypadDisplayState?
    var navigation: WKNavigation?
    var acknowledgement: Binding<KeypadDisplayState?>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard let navigation, navigation === self.navigation else { return }
      acknowledgement?.wrappedValue = requested
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      invalidate(navigation)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      invalidate(navigation)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      acknowledgement?.wrappedValue = nil
      requested = nil
      navigation = nil
    }
    private func invalidate(_ navigation: WKNavigation?) {
      guard let navigation, navigation === self.navigation else { return }
      acknowledgement?.wrappedValue = nil
      requested = nil
      self.navigation = nil
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
}

/// Each responsive surface has its own render gate; an invisible alternative cannot acknowledge another view.
private struct KeypadSurface: View {
  let layout: KeypadDisplayState
  let keySize: CGFloat
  let gap: CGFloat
  let enabled: Bool
  let activate: (TileSnapshot, KeypadDisplayState) -> Void
  @State private var rendered: KeypadDisplayState?
  @FocusState private var focusedKey: String?
  private var ready: Bool { rendered == layout }
  private var gridSize: CGFloat { keySize * 3 + gap * 2 }
  var body: some View {
    ZStack(alignment: .topLeading) {
      KeypadArtworkView(layout: layout, keySize: keySize, gap: gap, rendered: $rendered)
        .allowsHitTesting(false).accessibilityHidden(true)
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(keySize)), count: 3), spacing: gap) {
        ForEach(layout.tiles) { tile in
          Button {
            guard ready, enabled, !layout.demo else { return }
            activate(tile, layout)
          } label: {
            Color.clear.frame(width: keySize, height: keySize).contentShape(Rectangle())
          }.buttonStyle(KeypadButtonStyle())
            .disabled(!ready || !enabled || layout.demo || !tile.enabled || tile.action == "none")
            .focused($focusedKey, equals: tile.key)
            .overlay {
              RoundedRectangle(cornerRadius: 15)
                .strokeBorder(focusedKey == tile.key ? Color.accentColor : .clear, lineWidth: 3)
                .allowsHitTesting(false)
            }
            .accessibilityLabel([tile.sublabel, tile.label, tile.detail].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityHint(layout.demo ? "Sample only. Live controls are disabled." : tile.requiresHold ? "Opens confirmation before sending this action." : "Activates the displayed action.")
            .help(layout.demo ? "Sample only" : "\(tile.label) · \(tile.detail)")
        }
      }
    }
    .frame(width: gridSize, height: gridSize)
    .padding(18)
    .background(Color(red: 0.055, green: 0.068, blue: 0.085), in: RoundedRectangle(cornerRadius: 30))
    .overlay { RoundedRectangle(cornerRadius: 30).strokeBorder(.white.opacity(0.08), lineWidth: 1) }
    .onChange(of: layout) { _, _ in rendered = nil }
  }
}

struct KeypadView: View {
  @EnvironmentObject var model: DeckModel
  @State private var demo = false
  private let keySize: CGFloat = 116
  private let gap: CGFloat = 12
  private var gridSize: CGFloat { keySize * 3 + gap * 2 }
  private var demoTiles: [TileSnapshot] {
    [
      .init(key: "0", label: "Website", sublabel: "CLAUDE", detail: "Working", status: "WORKING"),
      .init(key: "1", label: "Mobile app", sublabel: "CODEX", detail: "Needs approval", status: "WAITING"),
      .init(key: "2", label: "API", sublabel: "CURSOR", detail: "Finished", status: "DONE"),
      .init(key: "3", label: "Design system", sublabel: "GEMINI", detail: "Ready"),
      .init(key: "4", label: "Long project name example", sublabel: "CLAUDE", detail: "Disconnected", status: "DISCONNECTED"),
      .init(key: "5", label: "No session", detail: "Available slot", enabled: false),
      .init(key: "6", label: "Previous", detail: "1 / 2", action: "previous", enabled: false),
      .init(key: "7", label: "Attention", detail: "1 waiting", status: "WAITING", action: "attention"),
      .init(key: "8", label: "Next", detail: "Page 2", action: "next")
    ]
  }
  private var tiles: [TileSnapshot] {
    if demo { return demoTiles }
    if let tiles = model.snapshot?.tiles, !tiles.isEmpty { return tiles }
    return (0..<9).map { .init(key: String($0), label: "No session", detail: "Waiting for connection", enabled: false) }
  }
  private var pageDescription: String {
    if demo { return "Sample layout · no actions will be sent" }
    if !model.connected { return model.snapshot == nil ? "Waiting for the local service" : "Last known layout · controls paused" }
    return "Page \(1 + (model.snapshot?.page ?? 0)) of \(model.snapshot?.pageCount ?? 1) · same artwork as your hardware"
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Keypad").font(.largeTitle.weight(.semibold))
            Text(pageDescription).font(.callout).foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          Toggle("Demo", isOn: $demo).toggleStyle(.switch)
            .help("Preview sample sessions. Demo never sends actions to your agents.")
        }
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 24) {
            keypad
            contextPanel.frame(width: 230)
          }
          VStack(alignment: .leading, spacing: 24) {
            keypad
            contextPanel
          }
        }
        if !demo && model.actionInFlight {
          ProgressView("Sending action to the selected session…").controlSize(.small)
        }
      }.frame(maxWidth: 920, alignment: .leading).padding(28)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
  private var displayState: KeypadDisplayState {
    .init(tiles: tiles, revision: demo ? nil : model.snapshot?.revision,
      instanceID: demo ? nil : model.snapshot?.instanceId, demo: demo)
  }
  private var keypad: some View {
    KeypadSurface(layout: displayState, keySize: keySize, gap: gap,
      enabled: model.connected && !model.actionInFlight, activate: perform)
  }
  private var contextPanel: some View {
    VStack(alignment: .leading, spacing: 20) {
      if demo {
        Label("Demo preview", systemImage: "play.rectangle").font(.headline)
        Text("These are sample projects. Every key is disabled so you can explore the design safely.")
          .font(.callout).foregroundStyle(.secondary)
        Button("Return to live keypad") { demo = false }.buttonStyle(.borderedProminent)
      } else {
        Label(model.connected ? "Service connected" : "Reconnecting", systemImage: model.connected ? "checkmark.circle.fill" : "arrow.clockwise")
          .font(.headline).foregroundStyle(model.connected ? .green : .orange)
        if model.connected {
          Text("\(model.observedSessionCount) observed session\(model.observedSessionCount == 1 ? "" : "s")")
            .font(.caption).foregroundStyle(.secondary)
          HStack(spacing: 16) {
            metric(model.snapshot?.summary.workingCount ?? 0, "Working")
            metric(model.waitingCount, "Waiting")
            metric(model.snapshot?.summary.doneCount ?? 0, "Finished")
          }
          if model.observedSessionCount == 0 {
            Text("Start an agent in a project to fill your first tile.").font(.callout).foregroundStyle(.secondary)
            Button("Connect agents") { model.showSetup = true }.buttonStyle(.borderedProminent)
          } else {
            Text("Select a project to open its session. Use Attention for requests that need a decision.")
              .font(.callout).foregroundStyle(.secondary)
          }
        } else {
          Text("Controls stay paused until the local service reconnects. Your agents can keep working in their original apps.")
            .font(.callout).foregroundStyle(.secondary)
          Button("Review setup") { model.showSetup = true }.buttonStyle(.bordered)
        }
        if !model.message.isEmpty {
          Label { Text(model.message).textSelection(.enabled) } icon: { Image(systemName: "info.circle") }
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        Text("Status guide").font(.subheadline.weight(.semibold))
        legend("Working", "circle.fill", .blue)
        legend("Needs your input", "exclamationmark.circle.fill", .orange)
        legend("Finished", "checkmark.circle.fill", .green)
        legend("Disconnected", "xmark.circle.fill", .red)
      }
      Text("Approval keys require a hold on hardware or confirmation in the app.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 20))
  }
  private func metric(_ count: Int, _ title: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(count, format: .number).font(.title2.monospacedDigit().weight(.semibold))
      Text(title).font(.caption).foregroundStyle(.secondary)
    }.accessibilityElement(children: .combine)
  }
  private func legend(_ title: String, _ symbol: String, _ color: Color) -> some View {
    Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
  }
  private func perform(_ tile: TileSnapshot, displayed: KeypadDisplayState) {
    guard !displayed.demo, displayed == displayState, model.connected,
      !model.actionInFlight, tile.enabled, tile.action != "none" else { return }
    let command = ActionCommand(action: tile.action, sessionId: tile.target,
      requestId: tile.requestId, choiceId: tile.choiceId, revision: displayed.revision,
      heldMs: tile.requiresHold ? 700 : 0)
    if tile.requiresHold {
      model.pendingConfirmation = command
      model.confirmText = "Confirm \(tile.label) for this exact session?"
    } else { model.perform(command) }
  }
}
