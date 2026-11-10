#!/usr/bin/env bash
# Shared helpers of the Motor toolchain build.

toolchain_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$@"
  else
    printf '[build-toolchain] %s\n' "$*"
  fi
}

toolchain_die() {
  echo "toolchain: $*" >&2
  return 1
}

# A shallow clone of the head of one branch of a repository, given as a URL or
# a path.
toolchain_fetch_branch() {
  local repository="$1" branch="$2" directory="$3" display_dir="$3"
  if [ -n "${TOOLCHAIN_ROOT:-}" ]; then
    display_dir="${directory#"$TOOLCHAIN_ROOT/"}"
  fi
  toolchain_log "fetching $repository (branch $branch) into $display_dir"
  git init -q "$directory" &&
    git -C "$directory" fetch --depth 1 "$repository" "refs/heads/$branch" &&
    git -C "$directory" -c advice.detachedHead=false checkout FETCH_HEAD
}

# The name rustup, the archives, and the Motor OS checkout know the toolchain
# by, from the Rust checkout's version and channel.
toolchain_name() {
  local rust="$1" release="$2" dev="$3" version channel name
  [[ "$release" =~ ^[1-9][0-9]*$ ]] ||
    toolchain_die "the release number is not a positive integer: $release" || return
  version="$(cat "$rust/src/version")" || return
  channel="$(cat "$rust/src/ci/channel")" || return
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    toolchain_die "not a Rust release version: $version" || return
  name="x86_64-unknown-motor-$version"
  [ "$channel" = stable ] || name+="-$channel"
  [ "$release" = 1 ] || name+="-$release"
  [ "$dev" = false ] || name+=-dev
  printf '%s\n' "$name"
}
