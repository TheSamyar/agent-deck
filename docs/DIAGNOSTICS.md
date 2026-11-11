# Troubleshooting Agent Deck

1. Open **Settings → Privacy → Review diagnostic report**.
2. Read the preview, then save a new JSON file if you want to share it.
3. Follow each check's `nextAction`. MasterHUB → Check controls verifies physical input without executing actions.

Reports contain a fixed schema: application version/build, installed process states,
and fresh hardware connection/error counts. They exclude chats, prompts, command
text, project names, account identifiers, credentials, environment variables and
personal paths. No network request or microphone access occurs. A missing/stale or
unverified hardware producer is reported as unknown, not healthy.

Process checks prove that the expected installed executable is running; they do not
prove service authentication or physical control outcomes. Use Check setup for
connection problems. Exports use private file permissions and never replace a file.

For the same read-only report without opening a window:

```sh
"$HOME/Applications/Agent Deck.app/Contents/MacOS/AgentDeck" --diagnostics
```

The command is available starting in 0.4.1. Do not run it on older versions, which
can interpret an unknown flag as a normal app launch. This command does not start
Agent Deck or its service, change preferences, send agent commands or test hardware.
