# Contributing

Start with the build and verification commands in README.md. Use disposable projects for approval testing; never approve an unrelated working session to exercise a test.

## Changes

1. Describe the observed behavior and expected result in an issue or pull request.
2. Keep changes focused and preserve exact session/request ownership.
3. Run the Node tests, Swift tests, and native integration harness.
4. Include screenshots for artwork changes and hardware results for input changes.

## Automated checks

The Native app workflow runs offline daemon, browser-extension, subscription-policy,
and dashboard checks on Linux before a native build is available. These checks use
fake CLIs, synthetic browser state, and temporary loopback servers; they do not use
account credentials or call models. Run the same focused checks locally with:

```sh
node --test daemon/*.test.mjs
node scripts/test-browser-bridge.mjs
python3 scripts/test-subscription-planner.py
python3 scripts/test-subscription-task.py
python3 scripts/test-robin-dashboard-qa.py
```

The macOS job also checks the real native browser host against an isolated service
with `python3 scripts/test-jarvis-native-bridge.py`, after the debug executables have
been built. Physical MasterHUB behavior and browser UI testing remain manual gates.

## Vendor SDK

The plugin targets .NET 10 and references the installed vendor SDK. Override its default location with `dotnet build plugin/AiAgentDeckPlugin.csproj -p:VendorSdkRoot=/absolute/path/to/sdk`. Vendor libraries are not project-owned MIT code; consult the vendor’s terms before redistributing SDK components.

## Review expectations

Report device model, macOS version, agent/host, and reproduction steps for hardware bugs. Remove prompts, tokens, commands, and private project paths from reports. See SECURITY.md for sensitive reports.
