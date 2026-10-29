#!/bin/sh
# Sestaví samostatnou datovka-ng.app s jádrem v Rustu uvnitř balíku.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cargo build --release -p datovka-ffi --manifest-path "$root/Cargo.toml"
cd "$root/app"
# Documents is synced by iCloud, which tags files with extended attributes that
# codesign rejects. Keep build output outside the synced folder.
out="$HOME/Library/Caches/datovka-build"
if [ ! -L build ]; then
  rm -rf build
  mkdir -p "$out"
  ln -s "$out" build
fi
flutter build macos --release
app="$root/app/build/macos/Build/Products/Release/datovka-ng.app"
mkdir -p "$app/Contents/Frameworks"
cp "$root/target/release/libdatovka_ffi.dylib" "$app/Contents/Frameworks/"
install_name_tool -id @rpath/libdatovka_ffi.dylib "$app/Contents/Frameworks/libdatovka_ffi.dylib"
/usr/bin/xattr -cr "$app"
codesign --force --deep --sign - "$app"
echo "Hotovo: $app"

# Installer: a disk image with the app and a link to /Applications.
dist="$root/dist"
stage=$(mktemp -d)
mkdir -p "$dist"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Aplikace"
rm -f "$dist/DatovkaNG.dmg"
hdiutil create -volname "Datovka NG" -srcfolder "$stage" -ov -format UDZO "$dist/DatovkaNG.dmg" >/dev/null
rm -rf "$stage"
echo "Instalátor: $dist/DatovkaNG.dmg"
