# Airadar for iOS

Swift 6 · SwiftUI · iOS 26 (Liquid Glass). Same backend, same features as the
Android app; the Live Activity / Dynamic Island target is phase 2.

```bash
brew install xcodegen
cd ios
cp Config.example.xcconfig Config.xcconfig   # fill in
xcodegen generate
open Airadar.xcodeproj
```

Put your team id in `Config.xcconfig` (`DEVELOPMENT_TEAM`), pick a device, run.

**Running on your own iPhone with a free personal team** works — plug the phone in,
choose it as the run destination, and on first launch trust the developer under
Settings › General › VPN & Device Management. Two limits of personal teams: they
cannot sign Associated Domains, so the project carries no entitlements by default
(universal `https://…/s/` links then open the web page instead of the app;
`airadar://` links and everything else work), and the build expires after 7 days —
run it again from Xcode. A paid Developer Program team lifts both: add
`CODE_SIGN_ENTITLEMENTS = Entitlements/Airadar.entitlements` to `Config.xcconfig`.

**To do once there's a paid Developer Program team — Live Activity push updates.**
Without the Push Notifications entitlement and an APNs key, the Live Activity only
gets new data (delays, gates, baggage belt) when the app itself runs: in the
foreground, or when iOS happens to grant a background refresh. Its countdown and
progress bar tick on their own, but nothing newer than the last fetch reaches it.
With a paid team:
- Request the activity with `pushType: .token` and send each activity's push token
  to the backend.
- Have the backend push an ActivityKit update to that token whenever its own
  flight poll sees a change, so the Lock Screen and Dynamic Island update with
  the app not running.
- Use push-to-start (iOS 17.2+) so the activity can begin before departure without
  the traveller opening the app; the "open Airadar to follow it live" reminder in
  `FlightReminders.swift` then goes away.

Google sign-in needs an **iOS** OAuth client in the Google Cloud console
(bundle id `com.airadar.app`); its id and reversed id go into
`Config.xcconfig`. The ID token is issued for the Web client (`GIDServerClientID`),
which is what the backend already verifies.
