#!/bin/sh
# Zabalí linuxové sestavení Flutteru do DatovkaNG-linux-<arch>.AppImage,
# jednoho souboru pro distribuce bez balíčků .deb (Fedora, openSUSE, Arch…).
# Použití: scripts/package-appimage.sh <složka bundle> <verze> <výstup.AppImage> [x86_64|aarch64]
#
# appimagetool a runtime jsou pevné verze z oficiálních vydání projektu
# AppImage na GitHubu a jejich otisk se kontroluje. GTK 3 se nepřibaluje,
# bere se ze systému (mají ho všechny běžné desktopové distribuce).
set -e
bundle=$1
version=$2
out=$3
arch=${4:-x86_64}
if [ -z "$bundle" ] || [ -z "$version" ] || [ -z "$out" ]; then
  echo "použití: $0 <bundle> <verze> <výstup.AppImage> [x86_64|aarch64]" >&2
  exit 1
fi
case "$arch" in
  x86_64)
    tool_sha=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
    runtime_sha=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d ;;
  aarch64)
    tool_sha=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
    runtime_sha=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444 ;;
  *) echo "neznámá architektura $arch" >&2; exit 1 ;;
esac
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
tool="$work/appimagetool"
runtime="$work/runtime"
curl -sSfL -o "$tool" \
  "https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-$arch.AppImage"
curl -sSfL -o "$runtime" \
  "https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-$arch"
echo "$tool_sha  $tool" | sha256sum -c -
echo "$runtime_sha  $runtime" | sha256sum -c -
chmod +x "$tool"

app="$work/AppDir"
mkdir -p "$app/usr/lib/datovka-ng"
cp -a "$bundle"/. "$app/usr/lib/datovka-ng/"
cat > "$app/AppRun" << 'EOF'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
exec "$here/usr/lib/datovka-ng/datovka-ng" "$@"
EOF
chmod +x "$app/AppRun"
for size in 64 128 256 512; do
  mkdir -p "$app/usr/share/icons/hicolor/${size}x${size}/apps"
  cp "$here/../branding/macos/AppIcon-$size.png" \
    "$app/usr/share/icons/hicolor/${size}x${size}/apps/datovka-ng.png"
done
cp "$here/../branding/macos/AppIcon-256.png" "$app/datovka-ng.png"
ln -s datovka-ng.png "$app/.DirIcon"
# Named after the application id, so the dock matches the window to it.
cat > "$app/cz.user.datovka_ng.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Datovka NG
Comment=Klient datových schránek
Exec=datovka-ng
Icon=datovka-ng
StartupWMClass=cz.user.datovka_ng
Terminal=false
Categories=Office;Network;
EOF
mkdir -p "$(dirname "$out")"
# The tool is itself an AppImage; extracting it avoids needing FUSE on CI.
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$arch" VERSION="$version" \
  "$tool" --no-appstream --runtime-file "$runtime" "$app" "$out"
rm -rf "$work"
echo "Balíček: $out"
