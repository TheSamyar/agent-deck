# Alfred and Agent Deck ownership

Decision: 2026-11-06. Keep two product repositories with independently built apps.
Do not create a repository for every helper or extension.

| Owner | Responsibilities | Repository |
| --- | --- | --- |
| Alfred | Server, owner identity, web UI, source grants, cases, approvals, operations worker, desktop assistant | `alfred` (separate private repository) |
| Agent Deck | MasterHUB USB/rendering, physical controls, agent observation/hooks, session focus, Mac/media shortcuts, local agent-service integration | `TheSamyar/agent-deck` |

## Current migration state

The Alfred repository contains the standalone desktop assistant: conversation,
voice, wake runtime, skills, notebooks, local action policies and read-only
Operations. It has its own bundle identity, preferences, Keychain services,
Application Support, cache and log paths. Local conversation and approved local
commands do not require MasterHUB or an Agent Deck installation. Operations uses
its own separately enrolled read-only server device credential. Server accounts,
source grants and deployed workers are not changed by this work.

Agent Deck's Alfred screen now opens the separate app. The old assistant code
and data remain available only through an explicit compatibility entry while
standalone acceptance completes. That host is inactive by default: it does not
resume wake capture or autopilot simply because hardware/status rendering creates
the old store. Hardware's Alfred shortcut opens the companion instead of silently
opening a microphone. Do not run both audio owners together.

`native/Sources/AlfredIntegration` provides the assistant's narrow local-agent
interface. `JarvisRuntime` depends on that interface; the concrete `DeckModel`
adapter remains in Agent Deck. The interface currently shares `DeckCore` wire
types inside this repository. It is not an independently versioned cross-repo SDK.

## Integration contracts

1. Remote Operations reads use Alfred's public API, `GET /api/operations/cases`,
   with a device-scoped `ald_` credential. No worker credential, browser session,
   Agent Deck local-service token or owner password is imported.
2. The local assistant interface exposes an observed session snapshot and five
   explicit supervisor routes: task listing, start, continue, browser observation
   and browser command. It does not expose hardware, arbitrary URL paths or an
   authority to bypass existing grants and confirmation checks.
3. Agent observation and requested actions are different capabilities. A status
   read never grants permission to dispatch agents, send messages or approve work.
4. Remote API wire models temporarily exist in both products for compatibility.
   `AlfredCore` in the Alfred repository owns future Operations contract changes;
   preserve matching fixtures when updating Agent Deck's compatibility copy.
   Neither product builds against an uncommitted sibling checkout.

## Remaining acceptance and retirement

1. Complete microphone, playback and acoustic wake checks in the separate app.
   Automated fixtures use injected reasoning and no capture or provider requests.
2. Pair request-specific voice approvals independently before retiring the old
   approval client. Alfred deliberately cannot impersonate Agent Deck's GUI
   identity. Existing browser control requires an explicitly enabled Agent Deck
   connection and the sites already approved in its companion.
3. Review own-app provider credentials and project grants. The additive history
   migration never imports credentials, preferences, autopilot or sharing consent;
   missions resume as checkpoints and original files remain intact.
4. Remove compatibility code only after standalone acceptance. Alfred has its
   own signing/notarization artifacts and private manual preview releases. A future
   automatic updater must have its own feed and key, never Agent Deck's feed.

Source acceptance is an isolated Alfred package build and fixture
tests plus a compiling Agent Deck app with its runtime diagnostics still passing.
Live account enrollment, deployed server changes and final voice/hardware
acceptance remain separate from source-level verification.
