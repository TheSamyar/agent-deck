# Google and Slack personal connections

Robin's standalone application uses official APIs and your registered OAuth
applications. A ChatGPT/Claude subscription does not grant Gmail or Slack data
access. No application credentials, account tokens, or maintainer accounts ship
with the open-source platform.

## Google

1. Create an OAuth **Desktop app** client in a Google Cloud project. Enable the
   Gmail, Calendar, Drive, Docs, Sheets, Tasks, and People APIs you intend to use.
2. Configure the consent screen and add your account as a test user if the app is
   in testing. Sensitive/restricted scopes may require Google's verification for
   public distribution; testing authorization may expire under Google's policy.
3. Open Robin Settings → Personal connections, enter the client ID (and desktop
   client secret if your Google client requires it), and select sources.
4. Leave write access off for reading only. Enable it explicitly when connecting
   if you want confirmed external actions. Finish consent in the official browser.

Google uses a random loopback callback port and S256 PKCE. Tokens and any supplied
client secret are stored in the macOS Keychain, never in project files.

## Slack

Create a Slack application with **PKCE enabled**. Register
`http://localhost:16687/robin/oauth` as its redirect. Request user scopes
`search:read,channels:read,groups:read`; add `chat:write` only for confirmed posting.
Desktop PKCE does not request bot scopes or send a client secret. Workspace
administrators may need to approve the app and requested scopes.

After connecting, select allowed channel names or IDs. Search queries are scoped
per channel and results are filtered again against the selected channel. An empty
channel selection never searches the workspace.

## Controls and limitations

- Each account has source toggles and separate AI-provider destination grants.
  New connections share no personal context with an AI destination by default.
- Search/read is supported for mail, upcoming primary-calendar events, Drive
  files, document text export, spreadsheet CSV export, task lists/tasks, contacts,
  and selected Slack channels. Mail searches enrich up to five messages.
- Prepared changes are local previews. The Settings confirmation button consumes
  the exact draft revision once before any external request. Supported writes:
  Gmail draft/send, Slack post, calendar event, document append, sheet range update,
  task create/update, and contact name update with source metadata/etags.
- A successful write reports **provider acceptance**, not independent readback
  verification. Network uncertainty does not retry or claim completion.
- Disconnect removes local credentials. Use provider account settings to revoke
  server authorization. Reconnect after revoked/expired consent or to add scopes.

The APIs are implemented and offline-tested; live account access requires client
registration and explicit consent. A setup-ready account is never shown as connected.

References: [Google desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app),
[Slack public-client PKCE](https://docs.slack.dev/authentication/using-pkce/).
