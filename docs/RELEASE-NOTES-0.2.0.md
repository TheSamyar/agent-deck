# Agent Deck 0.2.0 — MasterHUB preview

A native Mac control surface for Cooler Master MasterHUB and coding agents.

- Agents: root sessions, exact-session focus, real approval requests, and status that includes outstanding shell and subagent work.
- Mac: navigation, scrolling, volume, zoom, and configurable rotary controls.
- Media: Spotify playback controls, live track state, and album artwork on the screen dial.
- Tools: quick utilities, device checks, visual customization, and optional activity motion with Reduce Motion support.
- Explore Demo: isolated sample sessions and local-only actions; no hardware or agent accounts required.

## Compatibility

Requires macOS 14 or later. The preview includes arm64 and x86_64 executables. Local
hardware checks cover the connected MasterHUB’s fifteen keys, two rollers, three small
dials, and rotating screen dial. Intel execution and additional Macs remain unverified.
Other vendor keypads are experimental source integrations and are not bundled here.

Agent visibility depends on provider lifecycle evidence and verified process ownership.
A process merely existing does not make a session Working. Unknown or disconnected
history is excluded from the default Agents page. External CLIs need current hooks;
Codex requires reviewing changed hooks in `/hooks`.

## Mac permissions

Agent Deck uses Input Monitoring for device events, Accessibility for Mac controls,
and Automation for supported application actions. Permissions belong to the native app.
Approval requests remain bound to the identified session and request; destructive
responses require a hold or confirmation. Unsupported decisions remain in the original
agent interface.

## Distribution status

Release candidate preparation only. The candidate is Developer ID signed as the maintainer;
Apple notarization is complete; public update hosting remains pending. The repository is
private and nothing has been published. Synthetic launch assets are clearly labeled
and contain no real prompts, approvals, or music playback.
