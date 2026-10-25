#!/usr/bin/env bash
# The Linux-host toolchain: the LLVM tools it carries, then rustc, Cargo, and
# the host and Motor standard libraries, installed by Rust bootstrap.

# The tools the cross wrappers and the Motor OS build run, as real files: the
# LLVM build's aliases are symlinks, which the archives cannot carry. ld.lld,
# which clang's Motor driver looks for beside clang, runs rust-lld instead of
# being another copy of lld.
TOOLCHAIN_HOST_LLVM_TOOLS=(clang llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip llvm-readelf)

toolchain_stage_host_tools() {
	local prefix="$1" llvm_build="$2" clang_major="$3" host tool
	host="$prefix/lib/rustlib/x86_64-unknown-linux-gnu"
	mkdir -p "$host/bin" "$host/lib/clang/$clang_major" || return
	for tool in "${TOOLCHAIN_HOST_LLVM_TOOLS[@]}"; do
		cp -L "$llvm_build/bin/$tool" "$host/bin/$tool" || return
	done
	cp -L "$llvm_build/bin/lld" "$host/bin/rust-lld" || return
	printf '%s\n' '#!/bin/sh' \
		'exec "$(dirname "$(readlink -f "$0")")/rust-lld" -flavor gnu "$@"' \
		> "$host/bin/ld.lld" || return
	chmod 0755 "$host/bin/ld.lld" || return
	cp -R "$llvm_build/lib/clang/$clang_major/include" "$host/lib/clang/$clang_major/"
}

# The LLVM tools and the cross wrappers go in first: the bootstrap's Motor
# target compiles and links with them.
toolchain_build_host() {
	local rust="$1" llvm_version
	toolchain_prepare_rust_analyzer || return
	toolchain_build_standalone_llvm "$rust/src/llvm-project" "$STANDALONE_LLVM_BUILD" || return
	llvm_version="$("$STANDALONE_LLVM_BIN/llvm-config" --version)" || return
	CLANG_MAJOR="${llvm_version%%.*}"
	toolchain_stage_host_tools "$TOOLCHAIN_PREFIX" "$STANDALONE_LLVM_BUILD" "$CLANG_MAJOR" || return
	toolchain_generate_cross_wrappers "$SYSROOT" "$CLANG_MAJOR" || return
	BOOTSTRAP_CONFIG="$WORK/bootstrap.toml"
	toolchain_render_bootstrap_config "$TOOLCHAIN_PREFIX" "$SYSROOT" \
		"$STANDALONE_LLVM_BIN" "$BOOTSTRAP_CACHE" "$TOOLCHAIN_NAME" \
		"$RUST_BUILD_DIR" > "$BOOTSTRAP_CONFIG" || return
	if ! (cd "$rust" && PYTHONDONTWRITEBYTECODE=1 \
		MOTOR_RUST_ANALYZER_CARGO_CONFIG="$RUST_ANALYZER_CARGO_CONFIG" \
		./x.py --config "$BOOTSTRAP_CONFIG" install --stage 2); then
		toolchain_die "Rust bootstrap install failed"
		return 1
	fi
	toolchain_validate_prefix "$TOOLCHAIN_PREFIX"
}
