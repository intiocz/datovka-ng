#!/bin/sh
# Zabalí linuxové sestavení Flutteru do DatovkaNG-linux-<arch>.deb.
# Použití: scripts/package-deb.sh <složka bundle> <verze> <výstupní.deb> [amd64|arm64]
set -e
bundle=$1
version=$2
out=$3
arch=${4:-amd64}
if [ -z "$bundle" ] || [ -z "$version" ] || [ -z "$out" ]; then
  echo "použití: $0 <bundle> <verze> <výstup.deb>" >&2
  exit 1
fi
root=$(mktemp -d)
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$root/opt/datovka-ng" "$root/usr/bin" "$root/usr/share/applications" "$root/DEBIAN"
for size in 64 128 256 512; do
  mkdir -p "$root/usr/share/icons/hicolor/${size}x${size}/apps"
  cp "$here/../branding/macos/AppIcon-$size.png" \
    "$root/usr/share/icons/hicolor/${size}x${size}/apps/datovka-ng.png"
done
cp -a "$bundle"/. "$root/opt/datovka-ng/"
ln -s /opt/datovka-ng/datovka-ng "$root/usr/bin/datovka-ng"
# Named after the application id, so the dock matches the window to it.
cat > "$root/usr/share/applications/cz.user.datovka_ng.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Datovka NG
Comment=Klient datových schránek
Exec=/opt/datovka-ng/datovka-ng
Icon=datovka-ng
StartupWMClass=cz.user.datovka_ng
Terminal=false
Categories=Office;Network;
EOF
cat > "$root/DEBIAN/control" << EOF
Package: datovka-ng
Version: ${version}
Section: net
Priority: optional
Architecture: ${arch}
Maintainer: Datovka NG <https://github.com/intiocz/datovka-ng>
Depends: libgtk-3-0 | libgtk-3-0t64, liblzma5
Description: Klient datových schránek
 Datovka NG. Nesmí se prodávat (PolyForm Noncommercial 1.0.0).
EOF
mkdir -p "$(dirname "$out")"
dpkg-deb --root-owner-group --build "$root" "$out"
rm -rf "$root"
echo "Balíček: $out"
