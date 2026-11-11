# Cooler Master MasterHUB

Agent Deck includes native IOHID adapters for the 15-key keypad (`2516:01fe`),
two rollers (`2516:0204`), three knobs (`2516:0202`), and screen dial (`2516:0206`).
No vendor app or separate driver is required.
The app targets macOS 14 and later and builds for Intel and Apple Silicon.
Physical validation on both architectures remains required before claiming certification.

Only one app instance may own the deck. Volume and mute use CoreAudio directly,
without Automation permission. Shortcuts and agent focus still need Accessibility.

Open **MasterHUB** in the Mac app. The workspace displays all four modules and provides
**Agents** and **Mac** pages. The Agents page has ten live session positions and five
navigation/action controls. The Mac page has ten customizable native actions plus
navigation. Click a Mac key or rotary control to edit it; Apply commits the draft,
Cancel discards it, and Undo restores the previous configuration. Import previews
before applying. Export includes keys, rotary assignments, and orientation.

The Coding Desk preset uses volume/mute, zoom/reset, and scroll/Attention on the
three small dials. The two rollers default to vertical and horizontal scrolling.
The screen dial selects active agents across pages; pressing focuses the exact agent
shown at press-down. Sessions retain stable order, with pinned sessions first.
Mac actions work independently of the local agent service.

**Check controls** starts in safe identification mode: physical input highlights the
corresponding control without executing its action. Live tests distinguish an input
being observed from the user confirming its action. Approval, interruption, and lock
are blocked while checking. Connection alone never counts as verified input.

To record a check for the running candidate (about 5–10 minutes):

1. Open **MasterHUB → Check controls**. Opening starts fresh evidence; earlier inputs
   and confirmations are cleared.
2. In **Identify safely**, follow the named control. Press all 15 keys, turn both
   rollers in both directions, turn/press each small dial, and turn/press the screen
   dial. Use **Next module** to move through all 31 inputs.
3. Choose **Test assigned actions**. Exercise each control again and tick **Action
   worked** only after seeing its assigned outcome. Safe identification does not
   enable that checkbox. Blocked approval, interruption, and lock actions remain
   unverified and need a separate controlled safety check.
4. Choose **Export this check…** and save the JSON with the candidate's acceptance
   record. Export before closing: reopening starts a new check.

The export records the running app's version/build, check times, current connected
modules and observed HID vendor/product/location IDs, received inputs, and outcomes
explicitly confirmed by the user. It excludes serial numbers, prompts, and paths.
The device snapshot is current at export; input observations cover this check only.
It does not certify readability, reconnection, sleep/wake, latency, or other Macs.

Physical holds capture the displayed surface and use monotonic time. Changed layouts,
service instances, and request ownership invalidate stale actions. Approval retains
the 700 ms hold and one-time request checks. Mac focus and window discovery run in
the permission-granted GUI app through an authenticated, expiring helper lease.
No Node permission entry or helper Accessibility grant is required.

All four modules enumerate on the existing USB connection. Small-dial and screen-dial
input has been observed. After the HID startup fix, both rollers were physically
verified in both directions on the existing connection (74 decoded ticks across
71 reports, 2026-11-02). The three small dials subsequently passed all nine inputs (left/right/press),
and the screen dial passed all three inputs. The keypad passed all 15 individual
physical key inputs. Safe identification was exited afterward. Action outcomes remain separate
from input verification. The roller interface opens
and its decoder is tested. Startup sends the standard USB HID `SET_IDLE(0)` request
to the roller and small-dial modules, matching the Windows HID driver behavior.
This follows the hardware finding documented in [HubDeck recovery](https://github.com/Przemotar/hubdeck/blob/main/crates/mh-device/src/recover.rs).
The implementation checks USB vendor/product IDs and never resets devices or writes
firmware. `rollerInitialization` and `knobInitialization` report 0 when USB accepts
the request; that is separate from receiving physical input. Diagnostics are recorded
in `~/Library/Caches/AgentDeck/masterhub-diagnostics.json`.
Firmware updates and network control of other Macs are outside this integration.

## Protocol references

The adapter independently implements the documented input framing, software-mode
feature report, and per-key JPEG output framing described by
[OpenStreamHub](https://github.com/goniszewski/OpenStreamHub), an unofficial
MIT/Apache-2.0 project. No upstream source is vendored. MasterHUB is a Cooler Master
product; this integration is independent of Cooler Master.

## Hardware acceptance

The read-only probe on the connected rig reports a 64-byte input report and
320-byte output report for the keypad, and 64-byte reports for the rollers.
Compilation and protocol tests do not establish physical acceptance.

Before certification, verify every key's label/action pair and upright artwork,
press/release and 700 ms holds using a disposable permission request, stale layout
rejection, unplug/replug, sleep/wake, simultaneous Logitech use, and execution on
one Intel and one Apple Silicon Mac. Do not use live approvals as a test.

## macOS permission identity

Device access and Mac actions run in the native Agent Deck bundle. The native service
never sends focus actions to the retired Node daemon. Native installation disables
only `com.ai-agent-deck.daemon`; unrelated Node applications and permission entries
are untouched. `--keep-legacy` retains the old service explicitly for legacy hardware.

When installing with `AGENT_DECK_SIGN_IDENTITY`, the build records that certificate
in `~/Library/Application Support/Agent Deck/build-signing-identity.txt`. Subsequent
builds reuse it so macOS permission identity survives code changes. An old ad-hoc
permission entry may need to be replaced once with the certificate-signed app.

## Repair permissions from the app

Click **Fix Mac permissions** in the dashboard banner or open **Settings → Permissions**.
The screen checks access automatically and opens the matching System Settings page.
If an enabled entry is stale, **Repair old permissions…** asks before clearing only
Agent Deck's Accessibility and Input Monitoring entries. Turn Agent Deck's switches
on again, then click **Restart Agent Deck**. **Show this app in Finder** reveals the
exact installed bundle if macOS requires it to be added manually. The app does not
grant itself access or change other apps' entries.

## Hardware validation

Run Check controls with the existing connection. Turn each roller and dial, press
each dial, and press the keypad. Confirm action behavior separately in live-test mode.
The app reports connected, input observed, and action confirmed as separate states.
Automated decoder/rendering tests and a universal build do not certify physical
operation on every Mac. Intel and Apple Silicon hands-on validation remains required.

## Media and Tools pages

Agents, Mac, Media, and Tools are available in the workspace page picker. The
physical page key cycles Mac → Media → Tools → Agents. Media provides Spotify
play/pause, skip, shuffle, repeat, launch, and system volume/mute. Spotify actions
run in the GUI app and may require its Spotify Automation permission. Tools provides
copy/paste, undo/redo, find/save, application switching, region capture, Spotlight,
and opening Agent Deck. Keyboard tools act on the currently focused application.
These pages remain available while the agent service is offline.

Key artwork uses large symbols, saturated color panels, and one short label rather
than tiny secondary text. Animated display scheduling remains unfinished; this
installed revision uses static artwork.

## Root-session lifecycle

An editor window does not create an agent session. Claude subagent events and Codex
subagent/guardian provenance do not become top-level deck entries. Codex provenance
is read from its local state database using only source/archive columns; prompts and
transcripts are not queried. Missing/unsupported metadata is unverified, not guessed.
Cursor hooks retain conversation IDs; an old hook lease becomes unverified.

The hook resolves the actual CLI ancestor and records its PID plus kernel process
birth time. Health checks remove exited/reused owners, and focus/interruption recheck
birth identity at action time. A Codex end-of-turn does not erase the owner PID.
Restarted history remains unverified until new evidence arrives. Session identity,
provider provenance, process ownership, and busy/idle state are separate concepts.

Display writes use one serial background queue. Each owner keeps one frame in flight
and the latest desired content. Context changes become interactive only after display
completion; held input retains its captured target. Animation is bounded to four dial
frames per second and at most two key images per key animation cycle. Reduce Motion,
safe identification, disconnect, and sleep stop animation. Local diagnostics include
frame duration and counts without track titles or artwork URLs.

The default Agents page shows working, waiting, and error root sessions only. Settings
can explicitly include idle/finished verified roots. Unknown and disconnected sessions
remain excluded in either mode. The integration harness also checks that a stale process
birth is rejected before GUI focus, and a disposable native owner process test verifies
live-owner survival followed by automatic disconnection on exit.

A root remains Working while a shell, tool, or subagent is outstanding. The round
screen identifies Shell running, Subagents running, or Processing results. A child
finishing does not finish its parent: a final root Stop with no outstanding work
confirms Done. Actual approval/input requests use Needs input. Child work aggregates
under its root instead of creating extra agent tiles; stale turn completions are ignored.
