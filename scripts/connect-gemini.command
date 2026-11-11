#!/bin/zsh
# Official OAuth sign-in in an empty workspace; no API keys or project config.
set -eu
robin_login_dir=$(/usr/bin/mktemp -d -t robin-google-login)
trap '/bin/rm -rf "$robin_login_dir"' EXIT
robin_gemini_binary=''
for candidate in "$HOME/.local/bin/agy" /opt/homebrew/bin/agy /usr/local/bin/agy; do
  if [[ -x "$candidate" ]]; then robin_gemini_binary="$candidate"; break; fi
done
if [[ -z "$robin_gemini_binary" ]]; then
  print 'Install the official Antigravity CLI first: https://antigravity.google/docs/getting-started'
  read 'reply?Press Enter to close.'
  exit 1
fi
cd "$robin_login_dir"
print 'Robin: sign in with your Google account in Antigravity. API keys and extra AI credits are disabled.'
print 'When sign-in finishes, press Ctrl+C to return to Robin.'
/usr/bin/env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" TERM=xterm-256color LANG=en_US.UTF-8 "$robin_gemini_binary" --settings '{"modelProvider":"","useG1Credits":false,"toolPermission":"strict","agentMode":""}'
