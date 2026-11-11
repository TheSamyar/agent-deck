# Agent Deck 0.3.8 development preview — build 14

Alfred now has its own application. The Alfred screen opens the installed
companion with the expected bundle identity; its physical shortcut opens the app
rather than starting voice capture inside Agent Deck.

The legacy assistant remains an explicit compatibility option while separate
voice-approval pairing and hardware acceptance finish. It stays inactive by
default, including automatic wake/agent-review behavior, and refuses activation
while the separate Alfred app is running. Existing settings and data are preserved.

Agent Deck retains MasterHUB, agent observation/hooks, session focus and Mac/media
controls. Its existing update feed and signing key continue to belong to Agent Deck.
Alfred's source, resources, credentials and release process live in its own private
repository. No source-account or production-server enrollment changed.

Physical input evidence applies to the previously tested build 12. This source
refactor does not certify a new hardware or acoustic test.
