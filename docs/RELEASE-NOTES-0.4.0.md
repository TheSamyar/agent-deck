# Agent Deck 0.4.0 development preview — build 15

MasterHUB now supports named profiles assigned to exact application bundle IDs.
Automatic switching is opt-in; manual selection pauses it, and unassigned apps
use your preserved Default. Settings identifies the last external app so returning
to the profile panel does not accidentally assign Agent Deck itself.

Profile switches wait for editing/checks, held controls, device writes, actions
and pending decisions. Editing a named profile preserves Default. Corrupt or
externally changed libraries are not overwritten, and recovered profiles import
additively. See [profile instructions](MASTERHUB-PROFILES.md).

Agent task completion now observes process exit directly, fixing a hang that
could leave completed turns marked working.

Hardware diagnostics now identify their producing GUI process. Alfred's Health
screen requires fresh, matching producer information before reporting modules as
connected; stale or incomplete data remains unknown.

Physical switching and control outcomes require hands-on acceptance. Automatic
profiles are not enabled and no personal app assignments are created by updating.
