# Rvrb for iOS and macOS

A SwiftUI client for [RVRB](https://app.rvrb.one): channels, chat, voting, DJing from your RVRB queue, and the
channel's music played on your Spotify. One multiplatform target (iOS 26 / macOS 26), no dependencies.

It ports the logic of the terminal client, [Rvrb.TUI](https://github.com/Besselking/Rvrb.TUI).

This is an unofficial client, not affiliated with RVRB or Spotify.

## Building

Open `Rvrb.xcodeproj`, pick the **Rvrb** scheme and an iPhone simulator or "My Mac". For a device, set your own team
under Signing & Capabilities for each target, and change the bundle ids (`is.bes.Rvrb`, `.Share`, `.Widgets`) and
the app group `group.is.bes.Rvrb` to ones your team can use. The app group also appears in `Core/Session.swift`
and the entitlements under `Config/`.

```bash
xcodebuild -project Rvrb.xcodeproj -scheme Rvrb -destination 'platform=macOS' build
```

Files under `Rvrb/` are picked up automatically (synchronized folder).

To install a Release build of the Mac app (what Archive > Copy App does), quitting and reopening the running copy:

```bash
Scripts/install-mac.sh
```

Quitting while you're on the decks keeps your spot: the app tells RVRB it's a sleeping mobile client (kept for an
hour, its turns played server-side) and reconnects as the same client when it's opened again.

## Logging in

RVRB only logs in through Spotify and redirects back to its own web app. The app runs that login in a web view and
takes the `session` token from `https://app.rvrb.one/login/?session=…` when it gets there. Pasting that URL (or the
bare token) also works. The token is kept in the keychain. For development, `RVRB_TOKEN` in the scheme's
environment overrides it, and `RVRB_DEBUG=1` logs every websocket frame (subsystem `Rvrb`, category `socket`).

Log Out forgets the token and the web view's cookies on this device only; it doesn't call `/api/logout`, which
would disconnect your other clients too.

## Layout

| Folder | What |
|---|---|
| `Core/` | Lenient `JSON`, models, REST (`RvrbAPI`), keychain `Session`, Spotify link parsing. Shared with the share extension. |
| `Rvrb/API/` | JSON-RPC websocket (`RvrbSocket`), chat HTML → `AttributedString` |
| `Rvrb/Client/` | `RvrbClient` (room state, votes, DJ turns), `TrackQueue` (the DJ queue stack), `Player` (`playTrack`/`pauseTrack`), background and Live Activity support |
| `Rvrb/Views/` | SwiftUI: channel list, room (now playing, chat, composer), people inspector, queue, search, devices |
| `RvrbShare/` | Share extension: share Spotify tracks or playlists to Rvrb to add them to your DJ queue |
| `RvrbWidgets/` | The channel's Live Activity with vote buttons (iOS) |
| `Shared/` | Live Activity attributes and the vote intent, shared by the app and the widget extension |
| `Scripts/logo.swift` | Draws the app icon and logo into the asset catalog |

## Untested so far

- iOS sends `appState { hidden, mobile: true }` on backgrounding, per the spec: the server should then keep the
  connection for an hour, start Spotify playback itself (`playTrack: false`) and, per RVRB's developers, serve a
  DJ's next track server-side while the app sleeps. Not tried for long periods yet.
- Password-protected channels, whispers, skipping, and the other items in the
  [API notes'](https://github.com/Besselking/Rvrb.TUI/blob/main/docs/rvrb-api-notes.md) "Not explored" list.

## License

[MIT](LICENSE)
