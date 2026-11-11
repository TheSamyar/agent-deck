# Agent Deck 0.3.4 — Playful command center preview

- Four original project characters express actual working, dependency-wait, input, idle, completion, and error states. Customize character and color per project in Settings → MasterHUB.
- The round display shows up to four individual shell, subagent, and tool dependencies, with bounded count groups for crowded roots. Needs-input and unknown states remain distinct. Root completion gets a brief acknowledgement without changing the current focus target.
- Handoffs is available on the device and in the Mac sidebar. Latest outcomes survive service restarts; disconnected history cannot focus a stale process, and resolved input requests stop appearing as Needs input.
- The isolated demo includes animated shared artwork and a replayable work → dependency wait → input → completion scenario. Reduced Motion uses static state representations.
- Existing installations retain Classic until Playful is selected. Mac/Media bindings and approval protections are preserved. New installations default to Playful.

Unchanged media artwork and project styles are cached to avoid repeated drawing and JSON decoding during animations.

Requires macOS 14+. Includes Apple Silicon and Intel executables; Intel execution and
additional Macs remain unverified. Final physical readability, reconnect/sleep, and
input/action acceptance require hands-on checks. Artifact references are unavailable
from current provider integrations; review results in the original agent.

This is a preview, not stable hardware certification. Source and download publication
require separate approval. The intended update feed is staged; it is not publicly
reachable while the repository remains private. Never share signing keys or credentials.
