# Agent Deck 0.3.6 preview — build 12

- Private GitHub updates use the signed-in user's repository access, including an
  optional preview channel. Feed and archive signatures are verified before
  Sparkle receives the exact bytes; GitHub credentials stay inside GitHub CLI.
- Update restarts wait for pending approvals and supervised work. The newly
  installed app safely refreshes its service after replacement.
- Check controls guides all 31 physical inputs and records input observations
  separately from user-confirmed actions. Candidate-specific JSON progress is saved
  locally and can also be exported explicitly.
- Release preparation exports one clean source commit, runs checks, notarizes the
  universal app, and signs the feed and source/artifact provenance. Signing keys
  stay in the local Keychain.
- Stability measurements track actual process identities, diagnostics freshness,
  CPU, memory, and new transfer failures. An unchanged menu-bar count avoids
  unnecessary status-label redraws. Provider artwork reuses a bounded frame cache;
  decorative GUI motion uses bounded periodic updates and stops for quiet states.
  Dashboard animation is opt-in in General settings; agent states remain live in
  either mode. Physical display animation retains its own setting.

Requires macOS 14+. Physical control outcomes, reconnect/sleep, accessibility
interaction, and additional Mac models require candidate-specific hands-on evidence.
Build and test results alone do not certify hardware behavior. Existing private
preview installations need a one-time manual update to gain private delivery support.
