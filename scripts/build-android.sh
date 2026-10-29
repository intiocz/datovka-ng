#!/bin/sh
# Builds the Rust core for Android (cargo-ndk) and the Flutter APK.
# Needs ANDROID_HOME with an NDK, JDK 21 and `cargo install cargo-ndk`.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_HOME"/ndk/* | tail -1)}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
cd "$root"
cargo ndk -t arm64-v8a -t x86_64 -o app/android/app/src/main/jniLibs build --release -p datovka-ffi
cd app
flutter config --android-sdk "$ANDROID_HOME" >/dev/null
flutter build apk --release --target-platform android-arm64,android-x64 "$@"
mkdir -p "$root/dist"
cp build/app/outputs/flutter-apk/app-release.apk "$root/dist/DATOVKA.apk"
echo "APK: $root/dist/DATOVKA.apk"
