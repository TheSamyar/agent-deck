# Agent Deck native preview

Open `~/Applications/Agent Deck.app`.

The native app is a local preview, not a notarized public release. It includes Attention, Sessions, Activity, settings, onboarding, the menu-bar inbox, and a shared nine-key layout. All sessions are reachable through pages; their slots do not reorder with every status event.

## Build and install

1. Build the keypad plugin on a Mac with the Logi Plugin SDK installed: `node scripts/build-and-deploy.mjs`.
2. Build the universal app: `node scripts/build-native.mjs --universal --release --install`.
3. Verify the package: `node scripts/verify-native-release.mjs`.
4. Install the native runtime and selected integrations: `node scripts/install-native.mjs`. MasterHUB needs no Logitech software. Add `--with-keypad` only for the optional bundled vendor-keypad plugin and its installed service.
5. Open Agent Deck and test a project tile. Reload Cursor windows when convenient to activate the terminal bridge; the installer does not reload working editor windows.

Developers need Xcode, Node 26, and the vendor SDK/.NET SDK to rebuild the plugin. The resulting app bundles its Swift service, hook executable, hook/profile installer, editor extension, update framework, and compiled keypad plugin. End users do not need those development tools.

The installer preserves an existing legacy daemon on port 19420 and starts the native service on port 19421. Window focus and approvals use the native runtime. No action falls back to the legacy Node daemon. A clean installation uses native port 19420.

## Guided setup and connection checks

Open **Check setup** in the dashboard toolbar to review four steps: select hardware, install selected integrations, recheck permission, and verify one physical press. **Finish later** leaves setup incomplete and keeps Demo available.

The connection list reports two independent facts: **Hooks installed** means the expected native hook is present in the provider configuration; **observed sessions** counts current snapshots excluding disconnected or unknown restored history. It does not claim that a provider is running just because installation exited successfully. Partial, malformed, skipped, or externally owned configuration stays visible as needing attention. Codex notify owned by another integration is preserved; request controls remain limited to explicitly app-managed Codex sessions. Antigravity remains experimental.

The permission check uses the running app's Accessibility status. A switch left on in System Settings can be stale after signing changes. The app and service can also have different effective permissions: the final exact-session focus test displays the service action result. Never use a real approval or stop action to test setup. Reload Cursor windows only when convenient after installing the bridge; existing terminals are not reloaded automatically.

Plugin-file detection is an installation check, not physical device detection. The final checkbox is manual confirmation that the selected project key opened the correct session. It clears if the target session changes or the service disconnects, and does not certify an entire device family.

## What works

| Area | Implementation |
| --- | --- |
| Session identity | Provider session ID plus host identity; full-path/process fallback. Same-project sessions remain separate. |
| Attention | Oldest pending requests first, original command context, explicit confirmation in the app, held confirmation on the keypad. Unsupported prompts open their original session. |
| Claude Code | Private-socket permission hook returns the decision to its own waiting invocation. Cancellation and expiry invalidate controls. |
| Codex | Optional app-owned App Server sessions support structured command/file approvals and turn interruption. Existing unrelated desktop sessions are not claimed as controllable. |
| Cursor | Workspace-window focus; installed companion extension maps shell process trees to exact terminals. Activation requires an editor-window reload. |
| Terminal / iTerm | Identity-based native focus. Stop checks terminal foreground process ownership before signaling its process group. iTerm still needs a real-device integration pass. |
| Keypads | Six session slots, paging, Attention, adaptive single-session view, buffered layouts during holds, one-time commands, cached static artwork, and pushed state. |
| Privacy | Local SQLite metadata/history; pending command context is memory-only. Diagnostics omit prompts, paths, and command text. Notifications are opt-in with sound off. |

Gemini uses verified hook events for status. Antigravity's legacy hook installation is preserved; a native adapter is not certified. Unsupported providers and prompt shapes do not receive guessed approval keystrokes.

## Components and data

- `native/Sources/DeckCore`: contracts, actor-based state, SQLite, layout/artwork, and native window/process control.
- `native/Sources/DeckTransport`, `DeckService`, and `DeckHook`: bounded local HTTP/private-socket transport, event streaming, editor routing, and permission leases.
- `native/Sources/AgentDeck` and `DeckInstaller`: SwiftUI product surfaces and owned hook/profile installation with backups.
- `cursor-extension`: terminal process identity, terminal reveal, and private local connection. `plugin`: thin vendor adapter, artwork cache, hold input, and reconnect support.
- Runtime: `~/Library/Application Support/Agent Deck/deck.sqlite`, `~/Library/Caches/AgentDeck/{connection.json,deck.sock}`, and `~/Library/Logs/AgentDeck-service.log`.

The SQLite history is capped at 1,000 metadata events and seven days. Pending approvals are never restored from disk. Restored sessions start disconnected until their host or provider is observed again. The socket and connection file are readable only by the current user. Loopback HTTP requires a rotating bearer token and rejects browser origins. This protects against network/browser access; it does not attempt to isolate malicious processes already running as the same macOS user.

The optional [voice supervisor](SUPERVISOR.md) has separate user-owned transcript,
lesson, and managed-task storage. Its histories are not subject to the metadata
retention window. Cloud mode sends context and live audio to a provider; Local mode
uses loopback chat and on-device speech. The cloud credential is stored in Keychain.

## Protocol v2

`SessionSnapshot`, `PendingRequest`, `LayoutSnapshot` (represented by `DeckSnapshot`), `ActionCommand`, and `ActionResult` carry stable identities, capabilities, revision, and request provenance. Commands distinguish submitted responses from upstream acknowledgements.

| Endpoint | Purpose |
| --- | --- |
| `GET /status`, `GET /events` | Authenticated snapshot and server-sent updates |
| `GET /health` | Authenticated live background-service Accessibility status |
| `POST /action`, `/press/:key`, `/dial/*` | Exact actions, service-instance/revision-checked keypad input, navigation |
| `POST /hook/:agent/:event` | Private Unix socket only; permission hooks hold their own response channel |
| `POST /bridge`, `/codex/start` | Private editor registration; explicit managed Codex launch |
| `POST /preferences` | Typed, persisted preferences |

Allow requires either a 700 ms physical hold or explicit native confirmation. Unknown request IDs, wrong owners, repeated responses, expired requests, disconnected hooks, and stale layouts are rejected. The original permission flow remains available if the hook bridge is unavailable. The app does not change an agent's approval policy or sandbox settings.

## Verification

```sh
node --test daemon/*.test.mjs
swift test --package-path native
node scripts/test-native.mjs
node scripts/verify-native-release.mjs
node scripts/verify-native-live.mjs
```

The integration harness uses disposable homes, isolated ports/sockets, native hook subprocesses, and a mock Codex App Server. It checks authentication, same-project sessions, scoped approvals, hold enforcement, foreground-process interruption, cancellation, notify chaining, configuration preservation, and idempotent profile installation/removal. It does not run a model task or approve a working agent request.

## Public release gates

1. Developer ID Application signing and notarization. Only development identities are available on this Mac. Preview builds use ad-hoc or Apple Development signing; neither is a notarized public release.
2. An HTTPS Sparkle appcast and Ed25519 release key, supplied as `AGENT_DECK_UPDATE_FEED` and `AGENT_DECK_UPDATE_PUBLIC_KEY`. Updates remain disabled until both are configured. Run `scripts/notarize-native.mjs` with a stored notary profile, then `scripts/verify-native-release.mjs --public`.
3. Physical hold/release, paging, reconnect, and sleep/wake checks on both keypad models; exact-terminal verification in real Cursor and iTerm sessions.
4. Real Intel/macOS 14 execution, VoiceOver/contrast/Reduce Motion review, and p95 latency/CPU measurements. Both architectures compile, but cross-compilation is not runtime certification.
5. Seven days of daily use and an external beta on three Macs. Native Antigravity support, additional Codex question/form shapes, and live editor-session identity across duplicate window names need integration certification before advertising support.

The legacy app/service remain available during migration. No public release or GitHub publication has been performed.

The live verification script is read-only: it checks the installed signature, authenticated runtime, rejected unauthenticated access, keypad state, and process-identified last-reported window visibility. It never sends a key press or approval. Hook readiness recognizes the installer’s supported command shapes; complex external TOML notify forms can require manual review even when valid.

## Separate service identity

The dashboard uses `com.aiagentdeck.app`. Its background runtime lives in `Contents/Helpers/DeckService.bundle`, uses `com.aiagentdeck.service`, and declares background-only activation. This prevents window discovery from registering a second foreground dashboard and confusing macOS app activation. The old service executable path is a relative compatibility symlink; actual launches use the nested helper path.

Accessibility grants belong to each running identity. Enable Agent Deck Service separately for terminal/editor window focus; enabling Agent Deck alone is not proof of service access. Setup and Permissions show both checks and can reveal the exact `deck-service` executable for adding it to System Settings. Readiness is cleared on disconnect, token/port rotation and service-instance changes; delayed responses cannot overwrite the current service's permission state. The authenticated `/health` endpoint checks the service live and does not change permissions.

## Session recovery acceptance check

Run `node scripts/test-native-lifecycle.mjs` after building `deck-service` and
`deck-hook`. The disposable Codex owner checks process exit, resumed thread
identity, event-stream interruption/reconnection, runtime deletion, restart credential
rotation, and inactive restored history.
A missing socket or connection file makes the service exit; launchd or the
running dashboard restarts it and recreates both private endpoints.

For a real sleep/wake check (approximately 10 minutes):

1. Open Agent Deck and confirm a fresh Codex event appears.
2. Put the Mac to sleep for 60 seconds, then wake and unlock it.
3. Submit a harmless prompt in the same Codex session.
4. Within 15 seconds, verify dashboard reconnection and current session status.
5. Confirm only one service listens on port 19420; record failure details without prompts or tokens.

Sleep/wake and installed-app recovery require separate verification after installing
the new build. Automated process tests do not certify those behaviors.

Recovery validation: the lifecycle harness and native integration harness passed;
the Swift suite executed 108 tests with two skipped and zero failures. A signed
universal build was installed locally, its service and dashboard restarted, and
`verify-native-live.mjs` passed with fresh Codex Working events, authenticated
transport, a visible dashboard, and all fifteen MasterHUB keys rendered. Real
sleep/wake and physical input verification remain manual and unperformed.
