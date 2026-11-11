# MasterHUB installable preview

For one-command preparation from a clean commit using the release Mac's existing
Keychain credentials, follow [release automation](RELEASE-AUTOMATION.md). It preserves
the exact source archive and signed artifact provenance, and never installs or publishes.

Use [the acceptance record](RELEASE-ACCEPTANCE.md) for dated, candidate-specific
evidence. `node scripts/check-release-readiness.mjs` runs independent read-only
package and installed-app checks and reports manual gates separately. Pass `--app
'<candidate>/Agent Deck.app'` to inspect an isolated candidate. It never installs or
publishes, and passing automated checks does not close the hands-on gates.

To notarize and package an isolated candidate without replacing earlier artifacts:

```sh
node scripts/notarize-native.mjs --app '<candidate>/Agent Deck.app' --output-dir '<candidate>/notary'
node scripts/package-preview.mjs --app '<candidate>/Agent Deck.app' --output-dir '<candidate>/release'
node scripts/prepare-update-feed.mjs --app '<candidate>/Agent Deck.app' --output-dir '<candidate>/release' --artifact-url '<intended-public-HTTPS-ZIP-URL>'
```

Notarization uses `AGENT_DECK_SIGN_IDENTITY` and the stored
`AGENT_DECK_NOTARY_PROFILE`. Build the candidate with both update environment
variables described in [NATIVE.md](NATIVE.md) before signing. These commands upload
only to Apple's notarization service; they do not publish the app or update feed.

The first download targets MasterHUB. Other keypad plugins are experimental source
integrations and are not a dependency of this package. Existing stable-release gates
below still apply before claiming stable support.

1. Run Swift, Node, and integration tests; complete the MasterHUB hardware/action checks.
2. Build the universal app, configure Developer ID signing, notarization, and the signed update feed.
3. Run `node scripts/package-preview.mjs`. It requires all public verification gates,
   creates a versioned ZIP and SHA-256 checksum, refuses overwrites, and never publishes.
4. Prepare the signed feed with `node scripts/prepare-update-feed.mjs --artifact-url <public-HTTPS-ZIP-URL>`. It checks the app’s embedded update key, signs and verifies the exact archive and feed, and never publishes. Review artifacts, privacy, credits, release notes, screenshots, and tested-device limits.
5. Publish only after explicit approval. No public download exists until that happens.

For a vendor-keypad package, pass `--require-keypad` to the release verifier as an
additional gate. Do not require that plugin for a MasterHUB-only release.

# Stable-release checklist

Source availability does not certify a stable binary. Record the commit and evidence for every gate before tagging a stable release.

1. Run Node tests, Swift tests, and the native integration harness. Build the plugin with the documented vendor SDK, then build the universal app with `node scripts/build-native.mjs --universal --release --require-keypad`. Verify installation, repeated installation, upgrade, and removal in disposable homes.
2. On MX Creative Console and Loupedeck/Razer, verify readable labels, six-session paging, duplicate project names, focus, hold/release cancellation, approval acknowledgement, disconnect/reconnect, and sleep/wake. Record the exact models and host versions.
3. Test Cursor and iTerm exact-terminal targeting, Intel/macOS 14 execution, VoiceOver, contrast, and Reduce Motion. Measure latency and CPU. Complete seven days of daily use and an external beta on three Macs.
4. Configure Developer ID signing and the HTTPS Sparkle feed/key. Run the notarization script with a stored notary profile and `node scripts/verify-native-release.mjs --public`. Confirm vendor redistribution permissions and bundle the compiled plugin.
5. Prepare a versioned artifact, checksum, release notes, supported-capabilities table, and actual hardware/app screenshots. Review these before publishing. Never label an ad-hoc signed preview stable.

Unverified integrations remain experimental. Keep the legacy migration guide available for existing installations. See NATIVE.md for detailed release dependencies.

The intended feed and artifact URLs may be staged before publication, but they must
be publicly reachable before announcing automatic updates. A private GitHub repository
or an unpublished release is not a usable public update service. Do not change repository
visibility or publish artifacts without explicit approval.
