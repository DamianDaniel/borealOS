#!/bin/sh
set -e

VERSION=0.0.1
ARCH=$(dpkg --print-architecture)
ROOT=$(mktemp -d)
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/local/bin" "$ROOT/usr/share/doc/borealos-apt-skin"

gcc -I"$HERE/include" -O2 -o "$ROOT/usr/local/bin/apt" \
    "$HERE/src/apt_skin.c" "$HERE/src/theme.c" "$HERE/src/config.c" -lutil
gcc -I"$HERE/include" -O2 -o "$ROOT/usr/local/bin/boreal-apt" \
    "$HERE/src/apt_skin_toggle.c" "$HERE/src/theme.c" "$HERE/src/config.c"

chmod 755 "$ROOT/usr/local/bin/apt" "$ROOT/usr/local/bin/boreal-apt"
cp "$HERE/README.md" "$ROOT/usr/share/doc/borealos-apt-skin/"
cp "$HERE/debian/control.binary-template" "$ROOT/DEBIAN/control"
sed -i "s/^Architecture:.*/Architecture: $ARCH/" "$ROOT/DEBIAN/control"

cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    echo "borealos-apt-skin installed."
    echo "apt is now skinned. Run 'boreal-apt off' to disable, 'boreal-apt status' to check."
fi
exit 0
EOF
chmod 755 "$ROOT/DEBIAN/postinst"

OUT="$HERE/borealos-apt-skin_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$ROOT" "$OUT"
rm -rf "$ROOT"

echo "Built: $OUT"
