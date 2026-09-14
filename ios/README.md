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

Google sign-in needs an **iOS** OAuth client in the Google Cloud console
(bundle id `com.airadar.app`); its id and reversed id go into
`Config.xcconfig`. The ID token is issued for the Web client (`GIDServerClientID`),
which is what the backend already verifies.
