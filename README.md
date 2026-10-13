# Rvrb for iOS and macOS

A SwiftUI client for [RVRB](https://app.rvrb.one): channels, chat, voting, DJing from your RVRB queue, and the
channel's music played on your Spotify. One multiplatform target (iOS 26 / macOS 26), no dependencies.

The API behaviour it relies on is documented in `../../csharp/Rvrb/docs/rvrb-api-notes.md` (written while building
the terminal client); this app ports that client's logic.

## Building

Open `Rvrb.xcodeproj`, pick the **Rvrb** scheme and an iPhone simulator or "My Mac". For a device, set your team
under Signing & Capabilities (and change the bundle id `com.marijn.Rvrb` if needed).

```bash
xcodebuild -project Rvrb.xcodeproj -scheme Rvrb -destination 'platform=macOS' build
```

Files under `Rvrb/` are picked up automatically (synchronized folder).

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
| `API/` | Lenient `JSON`, models, REST (`RvrbAPI`), JSON-RPC websocket (`RvrbSocket`), keychain `Session`, chat HTML → `AttributedString` |
| `Client/` | `RvrbClient` (room state, votes, DJ turns), `TrackQueue` (the DJ queue stack), `Player` (`playTrack`/`pauseTrack`) |
| `Views/` | SwiftUI: channel list, room (now playing, chat, composer), people inspector, queue, search, devices |

## Untested so far

- iOS sends `appState { hidden, mobile: true }` on backgrounding, per the spec: the server should then keep the
  connection for an hour and start Spotify playback itself (`playTrack: false`). Not tried against the server yet.
- Password-protected channels, whispers, skipping, and the other items in the notes' "Not explored" list.
