#!/bin/sh
# Zabalí linuxové sestavení Flutteru do DatovkaNG-linux-amd64.deb.
# Použití: scripts/package-deb.sh <složka bundle> <verze> <výstupní.deb>
set -e
bundle=$1
version=$2
out=$3
if [ -z "$bundle" ] || [ -z "$version" ] || [ -z "$out" ]; then
  echo "použití: $0 <bundle> <verze> <výstup.deb>" >&2
  exit 1
fi
root=$(mktemp -d)
mkdir -p "$root/opt/datovka-ng" "$root/usr/bin" "$root/usr/share/applications" "$root/DEBIAN"
cp -a "$bundle"/. "$root/opt/datovka-ng/"
ln -s /opt/datovka-ng/datovka-ng "$root/usr/bin/datovka-ng"
cat > "$root/usr/share/applications/datovka-ng.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Datovka NG
Comment=Klient datových schránek
Exec=/opt/datovka-ng/datovka-ng
Terminal=false
Categories=Office;Network;
EOF
cat > "$root/DEBIAN/control" << EOF
Package: datovka-ng
Version: ${version}
Section: net
Priority: optional
Architecture: amd64
Maintainer: Datovka NG <https://github.com/intiocz/datovka-ng>
Depends: libgtk-3-0 | libgtk-3-0t64, liblzma5
Description: Klient datových schránek
 Datovka NG. Nesmí se prodávat (PolyForm Noncommercial 1.0.0).
EOF
mkdir -p "$(dirname "$out")"
dpkg-deb --root-owner-group --build "$root" "$out"
rm -rf "$root"
echo "Balíček: $out"
