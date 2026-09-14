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

Set your team under Signing & Capabilities, pick a device, run.

Google sign-in needs an **iOS** OAuth client in the Google Cloud console
(bundle id `com.airadar.app`); its id and reversed id go into
`Config.xcconfig`. The ID token is issued for the Web client (`GIDServerClientID`),
which is what the backend already verifies.
