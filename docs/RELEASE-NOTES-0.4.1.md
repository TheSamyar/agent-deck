# Agent Deck 0.4.1 development preview — build 16

The menu bar now observes changes to the attention count rather than every dashboard
telemetry update. Repeated CLEAR artwork frames use the existing bounded JPEG cache.
Live events, hardware animation and polling intervals are preserved.

Settings → Privacy now previews an actionable diagnostic report before saving.
The same fixed-schema report is available through `--diagnostics` without opening
a window or starting the service. Reports exclude conversation text, prompts,
credentials and personal paths; unavailable or stale hardware status remains unknown.
See [troubleshooting](DIAGNOSTICS.md).

Automatic profiles remain opt-in. Physical controls on this exact build require
hands-on acceptance; automated checks do not claim that physical test.
