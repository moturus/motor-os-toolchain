#!/usr/bin/env bash
# The two archives of a built toolchain and their checksums. motor-os-tar's
# tar writes them, the same program that unpacks them on Motor OS.

toolchain_render_linux_install() {
	local name="$1"
	cat <<EOF
#!/bin/sh
# Installs the Motor toolchain $name and links it into rustup:
#   install.sh [--prefix DIR]
# DIR defaults to ~/.local/share/motor/toolchains/$name; an earlier
# installation there is replaced.
set -eu
name=$name
EOF
	cat <<'EOF'
prefix="$HOME/.local/share/motor/toolchains/$name"
usage() { echo "usage: $0 [--prefix DIR]"; }
while [ "$#" -gt 0 ]; do
	case "$1" in
		--prefix) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; prefix="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) usage >&2; exit 2 ;;
	esac
done
command -v rustup >/dev/null 2>&1 || {
	echo "install.sh: rustup must be on PATH; install rustup before running this script" >&2
	exit 1
}
case "$prefix" in /*) ;; *) prefix="$PWD/$prefix" ;; esac
payload="$(cd "$(dirname "$0")" && pwd)/toolchain"
if [ -e "$prefix" ]; then
	[ -f "$prefix/manifest" ] || {
		echo "install.sh: $prefix exists and is not a Motor toolchain" >&2
		exit 1
	}
	rm -rf "$prefix"
fi
mkdir -p "$(dirname "$prefix")"
cp -R "$payload" "$prefix"
rustup toolchain link "$name" "$prefix"
echo "installed $name in $prefix"
EOF
}

# A Rush script: Motor OS has no POSIX sh. It replaces /devtools/llvm and
# /devtools/rust and copies the rest over what is there.
toolchain_render_native_install() {
	local name="$1"
	cat <<EOF
#!/system/bin/rush
# Installs the Motor toolchain $name into /devtools:
#   install.sh [--replace]
# A different toolchain in /devtools is replaced only with --replace.
name=$name
EOF
	cat <<'EOF'
case "$0" in */*) here="${0%/*}" ;; *) here=. ;; esac
replace=no
case "$#:$1" in
	0:) ;;
	1:--replace) replace=yes ;;
	*) echo "usage: $0 [--replace]" >&2; exit 2 ;;
esac
installed=
if [ -f /devtools/toolchain/manifest ]; then
	while read -r line; do
		case "$line" in toolchain=*) installed="${line#toolchain=}" ;; esac
	done < /devtools/toolchain/manifest
fi
if [ -n "$installed" ] && [ "$installed" != "$name" ] && [ "$replace" = no ]; then
	echo "install.sh: /devtools has $installed; pass --replace to install $name instead" >&2
	exit 1
fi
for tree in /devtools/llvm /devtools/rust; do
	if [ -e "$tree" ]; then
		rm -r "$tree" || exit 1
	fi
done
for overlay in llvm rustc rust-analyzer libc; do
	cp -r "$here/images/$overlay/devtools" / || exit 1
done
# The copies keep the modes the unpacking session gave the files, which no
# lower role may execute. Make the programs executable by every role, and
# the launchers editable by Interactive as well, as they are on the image.
chmod rwxr-xr-x /devtools/llvm/bin/* /devtools/rust/bin/* || exit 1
cd "$here/images" || exit 1
for launcher in */devtools/bin/*; do
	chmod rwxrwxr-x "/devtools/bin/${launcher##*/}" || exit 1
done
echo "installed $name in /devtools"
EOF
}

# Writes into the directory OUT the host archive (install.sh and the rustup
# toolchain directory), the native archive (install.sh, manifest, and the
# overlays), and a .sha256 file for each, replacing earlier ones of the same
# name. Each archive holds one directory named like it. The staged toolchain
# and overlays move into the archive directories.
toolchain_package() {
	local tar="$1" out="$2" stage="$WORK/package" host native
	host="motor-toolchain-$TOOLCHAIN_NAME-x86_64-linux"
	native="motor-toolchain-$TOOLCHAIN_NAME"
	mkdir -p "$stage/$host" "$stage/$native" || return
	mv "$TOOLCHAIN_PREFIX" "$stage/$host/toolchain" || return
	toolchain_render_linux_install "$TOOLCHAIN_NAME" > "$stage/$host/install.sh" || return
	cp "$stage/$host/toolchain/manifest" "$stage/$native/manifest" || return
	mv "$TOOLCHAIN_IMAGES" "$stage/$native/images" || return
	toolchain_render_native_install "$TOOLCHAIN_NAME" > "$stage/$native/install.sh" || return
	chmod 0755 "$stage/$host/install.sh" "$stage/$native/install.sh" || return
	rm -f "$out/$host.tar.zst" "$out/$host.tar.zst.sha256" \
		"$out/$native.tar.zst" "$out/$native.tar.zst.sha256" || return
	"$tar" -c --zstd -f "$out/$host.tar.zst" -C "$stage" "$host" || return
	"$tar" -c --zstd -f "$out/$native.tar.zst" -C "$stage" "$native" || return
	(cd "$out" && sha256sum "$host.tar.zst" > "$host.tar.zst.sha256" &&
		sha256sum "$native.tar.zst" > "$native.tar.zst.sha256")
}
