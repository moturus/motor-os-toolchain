#!/usr/bin/env bash
# Prepare a published crate with a Motor patch. Callers source
# toolchain-lib.sh.

toolchain_prepare_patched_crate() (
	set -euo pipefail
	local root="$1" name="$2" version="$3" checksum="$4" archive="$5" patch="$6"
	local temporary source
	[ "$(sha256sum "$archive" | awk '{print $1}')" = "$checksum" ] ||
		{ toolchain_die "$name $version archive checksum mismatch"; exit 1; }
	patch="$(realpath "$patch")" || exit 1
	mkdir -p "$root" || exit 1
	root="$(realpath "$root")" || exit 1
	temporary="$(mktemp -d "$root/.prepare.XXXXXX")" || exit 1
	trap 'rm -rf "$temporary"' EXIT
	tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$temporary" || exit 1
	source="$temporary/$name-$version"
	[ -f "$source/Cargo.toml" ] || { toolchain_die "crate manifest missing"; exit 1; }
	# Inside a worktree, such as the toolchain checkout's build directory, git
	# resolves a git-style patch against the worktree and skips its paths
	# without failing; the ceiling keeps it from finding one.
	(cd "$source" && export GIT_CEILING_DIRECTORIES="$temporary" &&
		git apply --no-index --check "$patch" && git apply --no-index "$patch") || exit 1
	mv -T "$source" "$root/$name-$version" || exit 1
	printf '%s\n' "$root/$name-$version"
)
