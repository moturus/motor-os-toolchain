#!/usr/bin/env bash
# The published crates rust-analyzer builds with Motor patches, shared by the
# host bootstrap and the native analyzer. The versions and archive checksums
# are in patches/crates.sh.

# Print the prepared source of one patched crate: the published archive from
# crates.io, checksum-verified, with patches/<crate>-<version>-motor.patch.
toolchain_rust_analyzer_crate() {
	local patches="$1" work="$2" name="$3" version checksum archive
	case "$name" in
		url) version="$MOTOR_URL_VERSION"; checksum="$MOTOR_URL_CHECKSUM" ;;
		inventory) version="$MOTOR_INVENTORY_VERSION"; checksum="$MOTOR_INVENTORY_CHECKSUM" ;;
		*) toolchain_die "unsupported analyzer patch: $name"; return 1 ;;
	esac
	archive="$work/$name-$version.crate"
	mkdir -p "$work" || return
	curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
		"https://static.crates.io/crates/$name/$name-$version.crate" -o "$archive" ||
		toolchain_die "cannot download $name $version" || return
	toolchain_prepare_patched_crate "$work" "$name" "$version" "$checksum" \
		"$archive" "$patches/$name-$version-motor.patch"
}

toolchain_render_rust_analyzer_config() {
	local url="$1" inventory="$2"
	toolchain_bootstrap_absolute_path url "$url" || return
	toolchain_bootstrap_absolute_path inventory "$inventory" || return
	printf '[patch.crates-io]\nurl = { path = "%s" }\ninventory = { path = "%s" }\n' \
		"$url" "$inventory"
}

toolchain_prepare_rust_analyzer() {
	RUST_ANALYZER_URL_SOURCE="$(toolchain_rust_analyzer_crate "$TOOLCHAIN_ROOT/patches" \
		"$WORK/patched-crates" url)" || return
	RUST_ANALYZER_INVENTORY_SOURCE="$(toolchain_rust_analyzer_crate "$TOOLCHAIN_ROOT/patches" \
		"$WORK/patched-crates" inventory)" || return
	RUST_ANALYZER_CARGO_CONFIG="$WORK/rust-analyzer-cargo.toml"
	toolchain_render_rust_analyzer_config "$RUST_ANALYZER_URL_SOURCE" \
		"$RUST_ANALYZER_INVENTORY_SOURCE" > "$RUST_ANALYZER_CARGO_CONFIG"
}

toolchain_fetch_rust_analyzer() {
	local rust="$1" prefix="$2" manifest
	# Cargo's cross-build resolver also requests host-platform dependencies.
	# Fetch the full lockfile before the offline native build.
	(cd "$rust/src/tools/rust-analyzer" && RUSTC="$prefix/bin/rustc" \
		"$prefix/bin/cargo" fetch --locked \
		--config "$RUST_ANALYZER_CARGO_CONFIG") || return
	for manifest in "$RUST_ANALYZER_URL_SOURCE/Cargo.toml" \
		"$RUST_ANALYZER_INVENTORY_SOURCE/Cargo.toml"; do
		RUSTC="$prefix/bin/rustc" "$prefix/bin/cargo" fetch --locked \
			--manifest-path "$manifest" || return
	done
}
