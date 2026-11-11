# Playful command center — 0.3.4

Four original vector characters reflect real lifecycle evidence: building, watching
outstanding work, requesting input, resting, completed, error, or unknown. Project
identity uses a deterministic hash, with optional per-project character/color overrides.
The native preview and hardware share the same bitmap renderer. Character preferences
are local; the isolated demo and synthetic renderer do not read or write them.

The round screen shows up to four individual shell, subagent, and tool dependencies
around the selected root, with bounded count groups for larger workloads.
Unknown metadata never becomes a fabricated progress percentage. A verified new root
completion produces a 1.5-second acknowledgement without changing the current action
target. Dependency completion alone never completes the parent. Motion remains bounded
by the existing serial writer and honors Reduce Motion; the Media page is unchanged.

## Handoffs

Handoffs retains up to 100 lifecycle records for seven days and presents the latest
handoff per root. It includes verified completion, error, and input states. Session time
is the duration since session creation, not a claimed per-turn execution measurement.
Restarted/disconnected history remains readable, with focus disabled until current
process evidence restores that capability. Request review captures the exact root and
pending request. Expired requests cannot be replaced with a different agent's request.

This preview opens results in the original agent. Providers currently supply no
completed-artifact references through these integrations, so artifact-opening actions
are unavailable rather than inferred from commands or transcripts.

## Compatibility and interaction

Older work/snapshot payloads remain decodable. Optional dependency records are capped
at 64 and use hashed identifiers, kind, and lifecycle state; raw provider IDs, prompts,
and command output are excluded. Aggregate counts still describe larger workloads.
Existing installations keep Classic until Playful is selected in Settings → MasterHUB.
New installations use Playful. Character/color changes preview and render immediately.

Handoffs is available from the Mac sidebar and the physical Agents page. Turn the
screen dial to select a handoff; press to focus its exact root. Existing request holds,
revision checks, captured input targets, and root-process checks remain in force.

The isolated demo has a replayable work → shell/subagent wait → input → completion
scenario. `--render-masterhub-preview <path> --character-sheet` writes an owned synthetic
comparison at actual key/dial pixel dimensions. It does not capture the desktop.
