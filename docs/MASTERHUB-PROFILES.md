# Profiles for your active app

Open Settings → MasterHUB → Automatic app profiles. Automatic switching starts off;
your existing Default layout remains the authority for unassigned apps.

1. Configure the layout you want, then save the current assignments as a named profile.
2. Switch to the target app and return to Agent Deck. The panel shows that last
   external app; assign its exact bundle identifier to the saved profile.
3. Enable automatic profiles. Unassigned apps use Default. Choosing a profile or
   Default manually pauses automatic switching until you enable it again.

Editing a selected named profile updates that snapshot, not Default. Replace,
delete and reassignment controls require an explicit decision. Names and bundle
identifiers are validated; profile snapshots cannot grant assistant permissions.

Switching is debounced and waits for editing/identification, held controls, display
writes, active actions and pending agent decisions. Old rendered inputs retain
their revision checks. Switching cancels old held-input state before showing the
new configuration. Device actions are never run merely because an app activates.

Profiles are private JSON in
`~/Library/Application Support/Agent Deck/masterhub-profiles.json`. Writes are
atomic, and unreadable/corrupt or externally changed files are preserved rather
than silently reset or overwritten. The existing `masterhubConfiguration.v2`
preference remains Default; profile selection does not replace it.

Alfred's encrypted backups can include the layout and profile library. Recovery
creates import files. Import them in Agent Deck, then review assignments before
enabling automatic behavior. Recovered profiles add snapshots with distinct IDs
and names on conflict; they never overwrite your active profiles or assignments.

Unit fixtures cover opt-in/exact matching, persistence/privacy, unsafe storage,
conflicting imports and safety fences. Physical automatic-switch acceptance is a
separate hands-on check; passing source tests does not certify physical controls.
