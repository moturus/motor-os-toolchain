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
[ -x "$payload/bin/rustc" ] || {
	echo "install.sh: toolchain payload is missing its compiler: $payload" >&2
	exit 1
}
if [ -e "$prefix" ]; then
	[ -x "$prefix/bin/rustc" ] || {
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

toolchain_render_native_install() {
	printf '#!/user/bin/rush\nname=%s\n' "$1" || return
	cat "$(dirname "${BASH_SOURCE[0]}")/toolchain-native-install.sh"
}

toolchain_check_compiled_paths() (
	set -euo pipefail
	local root="$1" path status
	find "$root" -type f \( -perm /111 -o -name '*.a' \) -print0 |
	while IFS= read -r -d '' path; do
		status=0
		LC_ALL=C grep -aEq '/devtools/|/system/bin/(rush|sh)|/system/bin:' "$path" || status=$?
		case "$status" in
			1) ;;
			0) echo "toolchain: obsolete compiled path in $path" >&2; exit 1 ;;
			*) exit "$status" ;;
		esac
	done
)

toolchain_validate_images() (
	set -euo pipefail
	local images="$1" path overlay
	for overlay in llvm rustc rust-analyzer libc motor helix sed lua quickjs javy wasmtime; do
		[ -d "$images/$overlay" ] || {
			echo "toolchain: missing overlay: $overlay" >&2; exit 1;
		}
	done
	# Motor tar accepts regular files and directories. Newline-free names also
	# let the guest installer batch find output without interpreting filenames.
	find "$images" -mindepth 1 -print0 | while IFS= read -r -d '' path; do
		[[ "$path" != *$'\n'* ]] && [ ! -L "$path" ] &&
			{ [ -f "$path" ] || [ -d "$path" ]; } || {
			echo "toolchain: unsupported archive member: $path" >&2; exit 1;
		}
	done
	for overlay in "$images"/*; do
		[ ! -e "$overlay/devtools" ] && [ ! -e "$overlay/system/bin" ] || {
			echo "toolchain: obsolete image layout in $overlay" >&2; exit 1;
		}
	done
	for path in llvm/user/lib/llvm/bin/llvm rustc/user/lib/rust/bin/rustc \
		rustc/user/lib/rust/bin/rustfmt rustc/user/lib/rust/bin/clippy-driver \
		rust-analyzer/user/lib/rust/bin/rust-analyzer \
		motor/user/bin/dev/lorry motor/user/bin/dev/gix motor/user/bin/dev/mdbg \
		motor/user/lib/imager/imager helix/user/lib/helix/hx \
		sed/user/bin/dev/sed lua/user/bin/dev/lua \
		quickjs/user/bin/dev/qjs quickjs/user/bin/dev/qjsc \
		javy/user/bin/dev/javy javy/user/bin/dev/wasmi \
		wasmtime/user/bin/dev/wasmtime wasmtime/user/bin/dev/wasmtime-rt; do
		[ -f "$images/$path" ] && [ -x "$images/$path" ] || {
			echo "toolchain: missing executable: $path" >&2; exit 1;
		}
	done
	toolchain_check_compiled_paths "$images"
)

# Explicit inputs let the main repository repackage native overlays without a
# compiler build or writes to the release directory. PREFIX adds the host archive.
# Both input trees are disposable and are consumed after validation.
toolchain_package() (
	set -euo pipefail
	local tar="$1" out="$2" name="$3" images="$4" prefix="${5:-}" stage package
	[[ "$name" =~ ^x86_64-unknown-motor-[0-9][0-9A-Za-z.-]*$ ]] || {
		echo "toolchain: invalid release name: $name" >&2; exit 1;
	}
	tar="$(realpath "$tar")"
	images="$(realpath "$images")"
	toolchain_validate_images "$images"
	if [ -n "$prefix" ]; then
		toolchain_check_compiled_paths "$prefix"
		[ ! -e "$prefix/lib/rustlib/x86_64-unknown-motor/sysroot/devtools" ] || {
			echo 'toolchain: obsolete cross-sysroot layout' >&2; exit 1;
		}
	fi
	mkdir -p "$out"
	out="$(realpath "$out")"
	stage="$(mktemp -d "$out/.package.XXXXXX")"
	trap 'rm -rf "$stage"' EXIT
	package="motor-toolchain-$name"
	mkdir "$stage/$package"
	mv "$images" "$stage/$package/images"
	toolchain_render_native_install "$name" > "$stage/$package/install.sh"
	chmod 0755 "$stage/$package/install.sh"
	toolchain_check_compiled_paths "$stage/$package/install.sh"
	if [ -n "$prefix" ]; then
		mkdir "$stage/$package-x86_64-linux"
		mv "$prefix" "$stage/$package-x86_64-linux/toolchain"
		toolchain_render_linux_install "$name" > "$stage/$package-x86_64-linux/install.sh"
		chmod 0755 "$stage/$package-x86_64-linux/install.sh"
	fi
	for package in "$stage"/motor-toolchain-*; do
		package="${package##*/}"
		printf 'toolchain: writing archive %s\n' "$out/$package.tar.zst" >&2
		"$tar" -c --zstd -f "$stage/$package.tar.zst" -C "$stage" "$package"
		printf 'toolchain: computing sha256 checksum for %s\n' "$package.tar.zst" >&2
		(cd "$stage" && sha256sum "$package.tar.zst" > "$package.tar.zst.sha256")
		mv "$stage/$package.tar.zst" "$stage/$package.tar.zst.sha256" "$out/"
	done
)

# The same entry point is used by make toolchain-archive.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
		echo "usage: $0 TAR OUTPUT NAME IMAGES [HOST_PREFIX]" >&2
		exit 2
	fi
	toolchain_package "$@"
fi
