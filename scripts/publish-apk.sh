#!/bin/sh
# Builds the signed release APK and stages it for the website's download:
# backend/downloads/Airadar.apk plus android.json (version, date, SHA-256).
# Then copy backend/downloads/ to the server (docker-compose mounts it into the
# backend container) — the site picks up the new build straight away.
set -e
cd "$(dirname "$0")/.."
# Gradle needs JDK 17; Homebrew's when nothing else is set.
if [ -z "$JAVA_HOME" ] && [ -d /opt/homebrew/opt/openjdk@17 ]; then
    export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
fi
./gradlew -q :app:assembleRelease
apk=app/build/outputs/apk/release/app-release.apk
[ -f "$apk" ] || { echo "No release APK — is release.storeFile set in local.properties?" >&2; exit 1; }
version=$(sed -n 's/.*versionName "\(.*\)".*/\1/p' app/build.gradle | head -1)
mkdir -p backend/downloads
cp "$apk" backend/downloads/Airadar.apk
sha=$(shasum -a 256 backend/downloads/Airadar.apk | cut -d' ' -f1)
printf '{"version": "%s", "date": "%s", "sha256": "%s"}\n' "$version" "$(date +%F)" "$sha" > backend/downloads/android.json
echo "Staged Airadar $version ($(du -h backend/downloads/Airadar.apk | cut -f1)) in backend/downloads/"
