# Preview acceptance record

Create one record for each candidate. Copy this file into the release's review folder;
replace every `unverified` with dated evidence or leave the gate open. Passing unit
tests, code signing, or connected-device diagnostics does not prove physical actions.

## Candidate identity

| Field | Record |
| --- | --- |
| Source commit and local changes | unverified |
| Version, bundle path, and executable SHA-256 | unverified |
| Tester, date, Mac model, architecture, macOS | unverified |
| MasterHUB modules and firmware | unverified |
| Archive SHA-256 and signed feed path | unverified |

## Automated evidence

1. Run the checks in [RELEASING.md](RELEASING.md) and retain their exit codes and logs.
2. Build into a new directory to preserve the current candidate:
   `node scripts/build-native.mjs --universal --release --output-dir /private/tmp/agent-deck-candidate-YYYYMMDD-N`.
   This refuses an output directory that already contains `Agent Deck.app`.
3. Run `node scripts/check-release-readiness.mjs --app '/private/tmp/agent-deck-candidate-YYYYMMDD-N/Agent Deck.app'`.
   Save its JSON outside the signed bundle. Exit 1 means at least one automated gate
   failed; exit 0 means only that the automated checks passed. Each child check has
   a 60-second timeout, reported separately from a failure.
4. Review candidate signature, notarization, and update configuration before installing
   the candidate for physical checks. A fresh local signature is not notarization.

The report inspects the chosen candidate and the separately installed app. Its source
commit is the checkout at inspection time, not proof of either binary's provenance.
Rebuild after source changes; retain the report matching the final candidate.

## Hands-on gates

| Gate | Bounded check | Result and evidence |
| --- | --- | --- |
| Readability and controls | Check all 15 labels/actions, both rollers in both directions, every dial direction/press, and screen selection/focus. Use Check controls identification first, then confirm outcomes separately. | unverified |
| Safety and recovery | Use disposable requests for the 700 ms hold and stale-layout rejection; verify unplug/replug and sleep/wake preserve the right target and recover displays. | unverified |
| Accessibility and performance | Exercise VoiceOver, contrast, Reduce Motion, sustained animation and input; record CPU, latency, duration, and failures. | unverified |
| Additional Macs | Record actual Intel/macOS 14 and Apple Silicon runs; cross-compilation alone does not pass this gate. | unverified |
| Update and launch review | Verify archive checksum and signed feed against the exact candidate, review release assets and limits, and record explicit publication approval. | unverified |
