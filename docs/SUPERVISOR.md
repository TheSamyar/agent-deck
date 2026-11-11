# Voice supervisor

Open **Supervisor** in the main window. Choose **Local** or **Cloud**, then open
**Setup & compare**. Nothing starts listening until you start a conversation or
press a MasterHUB key assigned to **Talk to Supervisor**.

## Setup

1. **Local:** use Install / open Ollama, Download model, then Check Local. The default
   `qwen3:4b` download is about 2.5 GB; 8 GB or more memory is recommended. Guided setup creates an `agent-deck-supervisor:latest` profile with a 16K context, and local requests disable extra reasoning for faster conversation. Downloads
   show progress and can be canceled. Local chat endpoints must be loopback addresses.
2. **Cloud:** save an API key in macOS Keychain. Cloud voice uses OpenAI Realtime;
   task review and text chat use the configurable chat model. Provider API charges
   are separate from agent CLI subscriptions. Model access depends on your account.
3. **Compare:** run the same sample separately in each mode. The app retains text,
   elapsed response time, model, and token usage when returned. No agent is prompted
   by a comparison sample. Actual dollar charges are available from your provider;
   the app does not invent a cost estimate.

Cloud voice uses native microphone capture, voice processing, server turn detection,
streamed speech output, and interruption/truncation. Its model and voice transport
are independent of the text model. Local voice uses on-device macOS speech recognition,
a local text model, and a dedicated Kokoro speech model. Setup & compare → Local
voice installs an isolated Python runtime and about 355 MB of checksum-verified
model files. Choose Heart (default), Bella, Michael, or Emma, adjust speed, and use
Preview voice before chatting. The model remains warm in a private stdio worker;
speech text and generated audio never use a network server. The basic Mac voice is
available only as an explicit fallback choice. The conversation automatically submits after a
1.2-second pause and resumes listening after the reply. Local mode takes turns;
it does not promise cloud-quality full-duplex speech. Unsupported local speech
languages show an error rather than falling back to cloud transcription.

Audio is never written to disk. Sleep and session deactivation stop voice.
The diagnostic sample command writes a WAV only when explicitly invoked; normal
conversation and preview playback stream PCM in memory. Stopping playback cancels
the inference request, discards late audio, and prevents microphone restart for that
utterance. Listening resumes only after all generated audio has played.
Speech preparation removes emoji sequences and decorative Markdown before synthesis,
including flags, skin tones, joined emoji, and keycaps; ordinary numbers are retained.

Every text/Local voice turn refreshes the full native agent snapshot as well as
managed tasks. The model receives provider/project names, observed activity, input
request titles, and counts. Empty managed-task history does not hide existing agents.
Unknown/disconnected sessions are excluded, and a lost service connection is stated
explicitly. Cloud voice receives refreshed context and can inspect the same overview.
Observed sessions expose status and tool metadata, not full transcripts; follow-up
control remains limited to managed tasks. Overview questions summarize agents without
requiring the user to name one first.
Ending a conversation stops capture and playback. Agent review can continue while
voice is off. Spoken agent alerts are enabled by default as requested and can be
disabled in Setup. Alerts do not open the microphone.

## Teach it

Your approved starting lesson is: **Keep replies short and simple. Give
multiple-choice options. Recommend one.**

Talk or type a correction. The model can propose a lesson, shown under **Remember
this?** Approve, edit, or discard it. During a voice conversation, the exact phrases
“save it”, “save that lesson”, or “approve lesson” approve the single pending lesson
after the recognized user transcript arrives. Model speech and tool arguments cannot
approve lessons. You can also write lessons directly and remove approved lessons.
Conversation transcripts are searchable in Talk.

## Keep agents working

Use **Tasks** to choose Codex, Claude, or Cursor, a project folder, a goal, and
acceptance criteria. Agent Deck launches the signed-in CLI without a shell and
records the exact provider session for continuation. Cursor uses its Agent CLI
(`agent` or `cursor-agent`), not an existing editor composer. Existing unrelated
editor or terminal conversations are not taken over.

When a turn ends, choose **Review next step**. The supervisor checks the reported
result against the original task and drafts a follow-up, suggests completion, or
asks for your decision. You can edit the prompt before sending it, or write one
yourself. Reported test evidence is agent-supplied; the supervisor does not
independently certify test results. Mark complete remains an explicit user action.

**Autopilot for this project** is opt-in. It reviews newly completed turns and sends
in-scope follow-ups. It never approves tool permission requests. Permission denials,
failed processes, malformed model decisions, repeated prompts, missing session IDs,
and five automatic follow-ups pause automatic continuation. Stopping a task disables
autopilot for its project. It stops the owned root process; independently launched
external background jobs may need separate inspection.

One supervised agent may write in a project at a time, including symlink aliases.
Every continuation checks the result revision; duplicate command IDs return their
prior receipt. A service restart changes running tasks to blocked. Persisted PID
and process-birth identity prevent resuming alongside a surviving old process.
Use Stop to terminate that exact process before continuing. Turns time out after
30 minutes and require review. CLI tool permissions and project configuration still
apply; unsupported CLI versions or missing authentication produce a blocked task.

Assign **Talk to Supervisor** to a Mac-page key in MasterHUB customization. The same
key starts or ends voice. Safe identification and device checks never start it.

## Storage and transport

`~/Library/Application Support/Agent Deck/supervisor.json` stores approved and pending
lessons, transcripts, project autopilot choices, and up to 500 review/action records.
`supervised-tasks.json` stores task goals, criteria, prompts, bounded agent results,
session IDs, and process identity. Files are user-readable only (0600). Transcripts
and task history remain until removed by the user; they are not part of the older
seven-day metadata-history retention policy. Comparison samples and non-secret
configuration are stored in application preferences. The cloud key is in Keychain.
CLI providers can retain their own session history under their normal policies.

Local mode sends chat only to a configured loopback server and never sends the cloud
key. Cloud chat sends recent conversation, approved lessons, and managed-task context
to the configured HTTPS endpoint. Cloud task reviews send the selected task and
lessons. Cloud voice sends live microphone audio and managed-task context to OpenAI.
Redirects are rejected so credentials and local requests cannot be redirected to
another server. Agent output is treated as untrusted evidence in model instructions.

Authenticated service endpoints: `GET /supervisor/tasks`, `GET
/supervisor/availability`, and `POST /supervisor/start`, `/supervisor/continue`,
`/supervisor/state`. These share the existing local bearer authentication and
browser-origin rejection. Restarted processes are never silently adopted.

## Validation

Run `swift test --package-path native` and `node scripts/test-supervisor.mjs`.
Run `python3 scripts/test-kokoro-voice.py` for voice protocol validation. With the
Local voice installed, `AGENT_DECK_TEST_KOKORO=1` enables real audio generation,
cancellation, and warm-worker reuse tests. The packaged app's
`--test-kokoro-playback` diagnostic plays a short Heart sample and verifies native
playback completion without opening the microphone.
The integration harness uses isolated fake CLIs for all providers, never live API
credits or existing sessions. It covers authentication, exact resume, duplicate and
stale commands, project serialization, permission denial, and service restart.

Cloud account access, actual microphone/speaker echo performance, local recognition
availability, and real provider CLI behavior still require a hands-on check on the
installed signed app. A successful build or fixture test does not certify those.

Protocol sources: [OpenAI Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations),
[Claude headless mode](https://code.claude.com/docs/en/headless),
[Cursor CLI parameters](https://docs.cursor.com/en/cli/reference/parameters),
[Ollama model pull](https://docs.ollama.com/api/pull), and
[the local model](https://ollama.com/library/qwen3:4b).

Robin is the assistant inside Agent Deck. Legacy jarvis.* preference keys, serialized configuration fields, and --export-jarvis-schema remain compatible. --export-robin-schema is an alias.

## Robin attention replies

Enable **Ask and listen for permission requests** in Robin settings. Pending
Allow once / Deny questions are announced one at a time while conversation is idle.
The microphone opens only after speech playback completes. Replies use on-device
recognition, including when cloud chat is selected. The configured local voice is
used when installed; otherwise announcements use the system voice.

Say **allow once** or **approve**, **deny**, **repeat**, **later**, or **stop listening**.
Only a finalized, whole explicit reply can submit a decision. Partial transcripts,
ambiguous replies, timeouts, stale questions, and disconnected GUI leases leave the
request unanswered. Approval proof is single-use, revision-bound and expires within
90 seconds. This does not simulate a held button or enable permanent permission.
Reply onset, silence duration and Later delay are configurable. Stop listening is
also available on screen. This flow handles permission hooks; managed-task review
and ongoing cloud conversations retain their existing controls.

## Full Robin assistant

Mission Control shows live Needs you / Working / Finished / Ready counts separately
from the visible session-card filter. Provider logos share their animated geometry
with the physical keys. Request details remain reviewable; graphics never grant a
permission or silently switch physical button targets.

Enable **Hey Robin — on-device wake listening** in Robin Settings. This keeps a
local microphone listener armed while idle. Ambient transcripts are discarded;
only finalized utterances beginning with **Hey Robin** reach command handling.
Try **Hey Robin, status**, **Hey Robin, open Codex**, **Hey Robin, draft a task fix
the login screen**, **Hey Robin, send my draft**, **Hey Robin, read my briefing**,
or **Hey Robin, stop listening**. Opening requires one exact agent/project match;
dictation preserves any existing unsent draft. Wake commands never approve tool
permissions. Other questions use the selected Local/Cloud assistant backend.

The wake listener pauses for speech playback, permission questions, conversations,
errors and service disconnects. Sleep/lock suspends it until Resume. Its microphone
state is shown in the Robin header and on the physical dial/Robin key. Microphone
and on-device Speech Recognition permissions are required from macOS. Voice and
recognition quality require a hands-on test on the installed machine.

Morning briefings run once per local calendar day after the configured hour
(default09:00), when the app is running, awake, connected, and audio is idle. A
**Read briefing now** button works on demand. The report uses observed completion
events and managed tasks, respects muted projects, and names the next pending
decision. The app does not claim tests passed or changes were verified from a Done
status. The last-delivery timestamp survives relaunches; this is an app schedule,
not a computer wake-up alarm.

Fresh observed root completions trigger a three-second green/reassembly sequence
on the exact finished key and screen dial, with queued spoken confirmation. Input
requests and errors take priority; completion does not interrupt speech or active
microphone replies. Historical results loaded on launch are never celebrated.
The **Speak fresh mission completions** setting disables spoken confirmations.

For this machine's explicit full-assistant setup, launch with
`--enable-robin-assistant` to enable wake, attention questions, daily briefing and
completion speech. Existing installs do not silently opt into wake capture.
`~/Library/Caches/AgentDeck/robin-health.json` contains only runtime readiness
flags/status, not microphone transcripts, project names or credentials.

## Robin reasoning and project notebooks

`--enable-robin-intelligence` enables the local reasoning controller using the
installed Qwen 3.5 9B with reasoning enabled. The same structured action schema and
application grants govern local and optional Groq planning. A Groq key uses a
separate Keychain entry; free-account confirmation and per-project cloud sharing
must be enabled explicitly in Settings. The app cannot establish an account's
billing tier from its key. It never upgrades the account or buys credits. Missing
credentials, rejected context, quota errors and outages use local reasoning.

Project notebooks store goals, unfinished work, decisions, approved preferences
and application-verified execution evidence. Memory can be inspected, corrected,
approved or forgotten. Project-scoped retrieval and contextual reference resolution
run in the actual request path. Cloud planning excludes global agent history and
raw receipts, rejects recognized secret patterns, and filters notebook source paths
through Git ignore rules; users should still only approve appropriate projects.

Missions persist their plan, action receipts, checks and blockers. Dispatching a
managed task is not completion. Exact test-running requests can finish from the
real approved test command's exit status; broad fixes additionally need evidence
for the requested behavior. Without that evidence Robin reports the remaining
verification instead of claiming success. Limits are32 actions, ten minutes checked
between operations, and three equivalent failures. An in-flight network request
may run until its own timeout. Restored checkpoints require observation; they are
not automatically executed.

Validation: `AgentDeck --test-robin-mission` uses an isolated temporary project and
non-persisting controller to exercise real harmless command success/failure. The
30-case evaluation catalogue and `scripts/evaluate-robin-reasoning.mjs` capture
planning outputs, not end-to-end completion scores. No measured improvement claim
should be made from structured-output validity alone. Live Groq testing requires
the user's separately configured free-plan account; local probes need no API key.

Local-model acceptance finding: the installed 9B model returned structured replies
in a simple probe but did not reliably choose a tool in the full action fixture.
Thinking plus JSON also exhausted its output budget in a candidate planning probe.
These are model capability/latency limits, not evidence of successful task work.
Exact approved test requests therefore use a deterministic project-scoped command
route; the isolated diagnostic separately proves actual command success/failure
classification. The optional stronger cloud planner remains untested without the
user's Groq setup. Do not describe this release as a proven model-intelligence gain.

Reliability policy after the model probe: a30-second thinking primary falls back
to a90-second direct structured response when truncated, invalid, empty or timed
out. A session circuit breaker keeps subsequent requests in direct mode until the
model changes or **Retry local reasoning** is selected. The UI explains the route.
The real execution diagnostic also checks selected-project isolation. It does not
claim the local model planned those commands: exact run-tests requests bypass it.

## All-provider model comparison (current)

Robin Settings now selects any of the eight comparison options: GPT-6 Astra,
GPT-6.1 Sol, Claude Fable 5.1, Claude Opus 5.5, Gemini 4 Argon, GPT-OSS 120B on
Cloudflare or Groq, and local Qwen 3.5 9B. Each provider has a separate Keychain
credential. Cloudflare additionally needs its account ID. Model access remains
unverified until a real request succeeds; selecting a model does not create an
account, purchase credit, or enable billing.

Explicit cloud selections apply throughout a mission. Project-context permission
is destination-specific; old Groq project permission is not expanded to other
providers. Safe project receipts and eligible file reads update planning context.
Unrelated app content, ignored/secret files and recognized credentials are withheld;
conversations fall back locally when context cannot be shared safely. Benchmarks
never fall back, so failures cannot be credited to another model.

**Compare performance** runs the same synthetic fixture and output limit across
selected/configured models. Proposed tool calls are never executed. Local runs
need no paid consent; cloud runs require a credential, explicit usage consent and
a positive whole-run estimated budget. Reservations stop before the next request
would exceed the estimate; unknown billed usage stops remaining cloud tests. This
is an application stop threshold, not an enforceable provider account billing cap.
Cancellation cannot undo a request already sent to a provider.

`output/robin-brain-picker/index.html` is now the month/performance dashboard.
Serve it with `python3 output/robin-brain-picker/serve.py` and open
`http://127.0.0.1:64783`. Its fixed `/metrics` endpoint returns whitelisted usage
metadata, never credentials or prompt/output text. Choice buttons save intent only.
Cloud tests and credentials stay in the native app, not the browser server.

The cross-process-safe ledger lives at
`~/Library/Application Support/Agent Deck/Usage/robin-model-usage.json`.
Recording failures leave persistent coverage warnings. Reported tokens, cached
input, reasoning output, retries, request duration, selected/actual model and
benchmark provenance remain distinct. Non-streaming requests have no measured
first-token time. Unknown usage is not silently filled with zero.

The dashboard distinguishes recorded UTC month-to-date reasoning usage, its
rate-card cost estimate, and a date-weighted next30-day workload forecast. These
are not reconciled invoices. Free allowances reset daily and may be shared with
other applications. Gemini's known December1 price increase is included. Fixed
platform fees are editable separately; voice, tools, electricity and unrelated
account usage are excluded. Synthetic valid JSON is not a task-completion score.

Validation: `AgentDeck --benchmark-robin-local --full-suite` records30 actual,
read-only local model attempts. Protocol tests cover all other adapters without
network access; cloud performance remains Not tested without configured keys.
`python3 scripts/test-robin-dashboard-qa.py` checks server boundary handling using
isolated temporary data and does not contaminate the real usage ledger.

## Existing ChatGPT subscription

The **ChatGPT subscription · Codex** brain uses the official installed Codex CLI's
existing ChatGPT sign-in. It does not extract OAuth tokens or reuse an API key.
The subprocess forces ChatGPT authentication, ignores user/provider configuration,
uses an isolated ephemeral working directory, disables built-in tools and rejects
unexpected tool events while reading output. Robin's own policy-controlled tool
execution remains separate. Cancellation/timeouts clean up the owned subprocess.

`--use-chatgpt-subscription` selects this route. The optional
`--use-chatgpt-subscription-project PATH` enables ChatGPT context for that path
only if it is already an approved Robin project; it grants no filesystem access.
Other providers' sharing grants are not broadened. Missing login, quota limits or
adapter errors fall back locally in conversations, never to a paid API provider.

This consumes ChatGPT/Codex plan allowance. Existing purchased-credit settings are
account-controlled and may apply; Robin does not purchase credits or change the
account's billing settings. Subscription tier/fee and remaining allowance are not
inferred from token counts. The dashboard has a user-entered fixed subscription
fee and keeps these records unpriced by API token rates. Standard API-token-cap
benchmarks exclude this route because CLI model/output limits differ.

`AgentDeck --test-robin-subscription` makes one harmless real subscription request,
validates the final structured response, and records only usage metadata. It uses
plan quota but does not execute proposed tools or inspect a user project.


## Subscription-only connections

**Robin → Settings → Subscription connections** exposes official CLI sign-ins
as an open-source feature. Every installation uses its owner's accounts; no
maintainer credentials, token extraction, or unofficial OAuth proxy is involved.

1. Install the vendor's CLI through its **Install / setup** link.
2. Copy its sign-in command and run it in Terminal: `codex login`,
   `claude auth login`, `agy` (choose personal Google sign-in), or `agent login`.
3. Finish the vendor's interactive sign-in, then choose **Check sign-ins**.
4. Select a supported **Use as brain** route and allow context for the selected
   project using the destination-specific context toggle.

Each connection shows its next setup action. **Open Terminal** opens Terminal;
paste the copied command there and complete sign-in yourself. **Use as brain**
becomes available only after **Check sign-ins** reports a signed-in connection
with planning support. Recheck after installing a CLI or changing its account.
If an installed CLI still shows **Install CLI**, ensure its executable is available
in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, or the app's `PATH`.

**Subscription only · block API billing routes** filters the brain picker to
subscription routes and local inference, switches voice to local, and blocks API
requests rather than trying API credentials. It does not modify vendor billing
settings. Shared quotas, purchased credits, and pre-existing extra-usage settings
remain vendor-controlled; subscription-only is not a guarantee of unlimited use
or a hard account spending cap.

Connection checks do not make inference requests. Installed, signed in, and
planning support remain distinct. The status helper emits sanitized metadata,
never credentials or raw vendor output. Missing/expired login, uncertain auth
mode, unsupported CLI isolation, or exhausted quota stops that subscription route;
no API fallback is attempted. Conversation fallback, when applicable, stays local.
The initial real planning request, rather than a status check, establishes working
model access.

Claude Code uses its official subscription sign-in. Gemini now uses the official
[Antigravity CLI](https://antigravity.google/docs/install), launched with `agy`.
Google [retired consumer Gemini CLI / Code Assist access](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals)
on June 18, 2026; old `gemini` consumer sign-in instructions no longer apply.
Use personal Google sign-in rather than API-key or Google Cloud/ADC modes.
Gemini/Antigravity supports supervised tasks through the official personal-account
route. API-key and ADC configurations are blocked. Gemini and Cursor planning
brains stay unavailable because their CLIs cannot enforce a hard no-tools
configuration; both appear as **Task agent only** in subscription connections.
Codex and Claude provide Robin planning as well as supervised task execution.
These routes do not impose a provider account spending cap: vendor allowance and
existing extra-usage settings still apply. Unsupported or unverified auth modes
stay blocked, and sign-in alone is not proof of working inference. Task-agent
permissions remain separate from Robin's planning brain. No task should be
reported as completed merely because an agent was dispatched.

For scripted setup, `--subscription-only` selects ChatGPT and enables the policy.
`--subscription-project PATH` alongside it enables context sharing with all four
subscription destinations only when PATH is already an approved Robin project.
The flag creates no filesystem grants and never broadens other projects.

API-token-cap benchmarks exclude subscription brains because vendor-selected
models and output controls differ. Their normal request timings remain recorded
separately. Subscription-only mode also skips paid API benchmark candidates.

## Active teammate conversations

Robin asks one focused question when an answer changes the work: goals, success
criteria, priorities, blockers, or review decisions. A pending question stays
visible with its project and original request. Answer in chat or use Resume
conversation for voice; playback finishes before the microphone opens.

Proactive nonurgent questions have a ten-minute cooldown. Say “later” to snooze
for fifteen minutes. Silence leaves the question visible without repeating it.
Routine idle chatter is excluded. Sleep, lock, mute, and permission prompts take
precedence. Ordinary conversation answers never approve permission requests.

Recent conversation context is scoped to the project and destination permission.
Older history without a project remains local. Explicit preferences can be kept
in the project notebook; temporary answers stay in the conversation.
