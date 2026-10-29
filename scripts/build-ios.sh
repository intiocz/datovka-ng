#!/bin/sh
# Builds the Rust core for iOS (device + simulator) and the Flutter iOS app.
# Signing for a real iPhone needs an Apple developer team set in Xcode.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
# target may link into Caches, which macOS empties when the disk runs low.
[ -L "$root/target" ] && mkdir -p "$(readlink "$root/target")"
for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  cargo build --release -p datovka-ffi --target "$t" --manifest-path "$root/Cargo.toml"
done
cd "$root/app"
flutter build ios --release "$@"
