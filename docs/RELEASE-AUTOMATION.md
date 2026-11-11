# Prepare a release from one clean commit

Run `git status --short` and `git rev-parse HEAD` first. Commit all release changes,
including the version/build bump, before preparing the candidate. The command
requires the full current commit ID and refuses staged, unstaged, or untracked files.
Ignored build outputs do not make the source dirty.

## Local credentials and update configuration

Signing stays on the release Mac. The orchestrator uses the existing Developer ID
identity saved by Agent Deck's installer, the `AgentDeck` notarytool Keychain profile,
and the `com.aiagentdeck.updates` Sparkle Keychain account. Override the identity with
`AGENT_DECK_SIGN_IDENTITY`, the profile with `AGENT_DECK_NOTARY_PROFILE`, or the update
account with `--key-account`. These are names of local credentials; private keys are
never exported or uploaded to GitHub. Apple's notarization service receives only the
signed candidate archive.

Set the existing public update configuration; the public key below is not a secret:

```sh
export AGENT_DECK_UPDATE_FEED='https://github.com/TheSamyar/agent-deck/releases/latest/download/appcast.xml'
export AGENT_DECK_UPDATE_PUBLIC_KEY='36e+YL+QV0SmoAHLtJqnqk564nD8+DxmOghuIzOTC74='
export AGENT_DECK_NOTARY_PROFILE='AgentDeck'
```

The artifact URL must name the exact versioned ZIP at the intended release tag.
Preparing an appcast does not make that URL publicly readable until the release asset is published.

## Inspect, then prepare

For a read-only five-minute performance check without opening demo windows, run:

```sh
node scripts/benchmark-native.mjs --seconds 300 --live-only
```

Keep the installed app running and leave its view unchanged during measurement.
The default benchmark also launches disposable active/idle demo windows; closing
one correctly marks that run incomplete. Neither mode presses physical controls
or sends agent commands. Test reconnect and sleep/wake separately with a person at
the device. Dashboard artwork is static by default; decorative animation is an
optional General setting with a higher CPU cost.

1. Preview the plan, replacing `<full-HEAD-commit>` with `git rev-parse HEAD` output:

   ```sh
   node scripts/release-native.mjs --commit <full-HEAD-commit> --artifact-url 'https://github.com/TheSamyar/agent-deck/releases/download/v0.3.6/AgentDeck-0.3.6-masterhub-preview-universal.zip' --plan
   ```

2. Run the same command without `--plan`:

   ```sh
   node scripts/release-native.mjs --commit <full-HEAD-commit> --artifact-url 'https://github.com/TheSamyar/agent-deck/releases/download/v0.3.6/AgentDeck-0.3.6-masterhub-preview-universal.zip'
   ```

3. Review `dist/release-<version>-build<build>-<commit-prefix>/release`. The command
   runs source tests, builds a universal app, verifies it, notarizes/staples it, packages
   the versioned ZIP, and signs/verifies the feed and provenance. A fresh export has
   its own SwiftPM build products; allow 10–30 minutes for the first build/downloads.

4. Complete the physical acceptance record and authorize installation/publication
   separately. The orchestrator never installs an app, creates a GitHub release,
   uploads GitHub assets, changes repository visibility, or publishes a feed.

Use `--output-dir <new-directory>` for another attempt. Existing output directories
are never overwritten, including partial failures. A failure stops subsequent steps
and preserves `release-inputs.json`, `release-failure.json`, and any completed outputs.
Do not treat the presence of a ZIP as completion: require the final provenance,
detached signature, and a successful exit code.

## Source and artifact provenance

The command exports only the exact committed Git tree using `git archive`, saves
`source.tar`, and builds from that isolated export. Later edits to the original
working tree cannot enter the build. Submodules are rejected because their content
would require additional capture. No ignored local files or maintainer runtime data
are copied into the source export.

`release/build-provenance.json` records the source commit/tree, source archive SHA-256,
version/build, public update configuration, completed checks, accepted Apple
notarization response, and SHA-256/size of the ZIP, checksum file, and signed feed.
The same existing Keychain update key signs the exact provenance bytes into
`build-provenance.json.ed25519`; `.sha256` provides a convenient additional digest.
Successful preparation refuses to replace these files. This evidence is tamper
evident, not a claim that signing/timestamps make independent rebuilds byte-identical.

To verify provenance locally, use Sparkle's build-resolved tool and the recorded
detached signature:

```sh
<output>/source/native/.build/universal/artifacts/sparkle/Sparkle/bin/sign_update --account com.aiagentdeck.updates --verify '<output>/release/build-provenance.json' '<signature-from-build-provenance.json.ed25519>'
```

## CI boundary

`node --test scripts/release-native.test.mjs` validates source pinning, clean-tree
enforcement, non-overwriting output, failure recovery, provenance signing, and the
absence of install/publication commands without needing credentials or hardware.
GitHub-hosted CI runs these tests; actual signing/notarization remains on the local
release Mac. Do not configure a public workflow to execute arbitrary pull-request
code on a Keychain-equipped self-hosted runner. No GitHub signing secrets or runner
registration are required by this implementation.
