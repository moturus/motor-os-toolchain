#!/usr/bin/env bash
# The manifest of a built toolchain names it. The host toolchain carries it as
# manifest, and every native overlay as devtools/toolchain/manifest.

TOOLCHAIN_OVERLAYS=(llvm rustc rust-analyzer libc)

toolchain_write_manifest() {
	local manifest="$TOOLCHAIN_PREFIX/manifest" overlay
	printf 'toolchain=%s\n' "$TOOLCHAIN_NAME" > "$manifest" || return
	for overlay in "${TOOLCHAIN_OVERLAYS[@]}"; do
		mkdir -p "$TOOLCHAIN_IMAGES/$overlay/devtools/toolchain" || return
		cp "$manifest" "$TOOLCHAIN_IMAGES/$overlay/devtools/toolchain/manifest" || return
	done
}
