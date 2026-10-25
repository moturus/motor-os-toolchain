#!/usr/bin/env bash
# The native rust-analyzer, linked through the cross sysroot's driver-managed
# libc link, and the rust-src it indexes.

toolchain_validate_native_rust_analyzer() {
	local binary="$1"
	[ -x "$binary" ] || { toolchain_die "analyzer is not executable: $binary"; return 1; }
	grep -aFq "$RUST_REV" "$binary" &&
		grep -aFq "$RUST_ANALYZER_RELEASE" "$binary" &&
		grep -aFq "$TOOLCHAIN_NAME" "$binary" || {
		toolchain_die "analyzer ELF lacks the source/release identity"; return 1;
	}
}

toolchain_rust_analyzer_release() {
	# Motor's bootstrap uses the dev channel; reject a changed channel until
	# its release-suffix rule and native recipe are reviewed together.
	[ "$MOTOR_RUST_CHANNEL" = dev ] || { toolchain_die 'unsupported native analyzer channel'; return 1; }
	RUST_ANALYZER_RELEASE="$RUST_VERSION-dev"
	[[ "$VALIDATED_RUST_ANALYZER_VERSION" == "rust-analyzer $RUST_ANALYZER_RELEASE ("* ]] || {
		toolchain_die 'host analyzer release differs from the native recipe'; return 1;
	}
}

toolchain_build_native_rust_analyzer() {
	local rust="$1" binary destination library
	toolchain_rust_analyzer_release || return
	(cd "$rust/src/tools/rust-analyzer" && \
		RUSTC="$TOOLCHAIN_PREFIX/bin/rustc" \
		CARGO_PROFILE_RELEASE_OPT_LEVEL=s \
		CARGO_TARGET_X86_64_UNKNOWN_MOTOR_LINKER="$SYSROOT/bin/motor-clang" \
		CARGO_TARGET_X86_64_UNKNOWN_MOTOR_RUSTFLAGS="-C link-self-contained=no -C default-linker-libraries=yes" \
		CFG_RELEASE="$RUST_ANALYZER_RELEASE" CFG_RELEASE_CHANNEL="$MOTOR_RUST_CHANNEL" \
		"$TOOLCHAIN_PREFIX/bin/cargo" build --release --locked --offline \
		--target x86_64-unknown-motor -p rust-analyzer \
		--config "$RUST_ANALYZER_CARGO_CONFIG" \
		--target-dir "$WORK/rust-analyzer") || return
	binary="$WORK/rust-analyzer/x86_64-unknown-motor/release/rust-analyzer"
	toolchain_validate_native_elf "$binary" "$STANDALONE_LLVM_BIN/llvm-readelf" "$binary" || return
	toolchain_validate_native_rust_analyzer "$binary" || return
	library="$TOOLCHAIN_PREFIX/lib/rustlib/src/rust/library"
	[ -f "$library/core/src/lib.rs" ] && [ -f "$library/std/src/lib.rs" ] ||
		toolchain_die 'rust-src is incomplete' || return
	destination="$TOOLCHAIN_IMAGES/rust-analyzer"
	mkdir -p "$destination/devtools/rust/bin" "$destination/devtools/rust/lib/rustlib/src/rust" || return
	# The compiler identity is in this non-allocated section; stripping it
	# would discard provenance while leaving the server's own version intact.
	"$STANDALONE_LLVM_BIN/llvm-strip" --keep-section=.comment \
		-o "$destination/devtools/rust/bin/rust-analyzer" "$binary" || return
	chmod 755 "$destination/devtools/rust/bin/rust-analyzer" || return
	toolchain_validate_native_elf "$destination/devtools/rust/bin/rust-analyzer" \
		"$STANDALONE_LLVM_BIN/llvm-readelf" "$binary" || return
	toolchain_validate_native_rust_analyzer "$destination/devtools/rust/bin/rust-analyzer" || return
	cp -a "$library" "$destination/devtools/rust/lib/rustlib/src/rust/" || return
	# These are analysis inputs, including host-only CI scripts, not guest tools.
	find "$destination/devtools/rust/lib/rustlib/src/rust/library" -type f \
		-exec chmod a-x {} +
}
