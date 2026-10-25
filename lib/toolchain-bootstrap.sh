#!/usr/bin/env bash
# Rust bootstrap configuration for the Motor toolchain, and the cross
# wrappers that compile and link for x86_64-unknown-motor.

toolchain_bootstrap_absolute_path() {
	local name="$1" value="$2"
	case "$value" in
		/*) ;;
		*) toolchain_die "$name must be an absolute path"; return 1 ;;
	esac
	case "$value" in
		*'"'*|*'\'*|*$'\n'*|*$'\r'*)
			toolchain_die "$name contains a character unsupported in bootstrap TOML"
			;;
	esac
}

toolchain_render_bootstrap_config() {
	local prefix="$1" sysroot="$2" llvm_bin="$3" cache="$4" description="$5"
	local build_dir="$6"
	toolchain_bootstrap_absolute_path prefix "$prefix" || return
	toolchain_bootstrap_absolute_path sysroot "$sysroot" || return
	toolchain_bootstrap_absolute_path llvm_bin "$llvm_bin" || return
	toolchain_bootstrap_absolute_path bootstrap_cache "$cache" || return
	toolchain_bootstrap_absolute_path build_dir "$build_dir" || return
	[[ "$description" =~ ^[A-Za-z0-9._+-]+$ ]] ||
		toolchain_die "invalid bootstrap description: $description" || return

	cat <<EOF
change-id = "ignore"
profile = "library"

[build]
host = ["x86_64-unknown-linux-gnu"]
target = ["x86_64-unknown-linux-gnu", "x86_64-unknown-motor"]
description = "$description"
build-dir = "$build_dir"
bootstrap-cache-path = "$cache"
submodules = false
extended = true
tools = ["cargo", "clippy", "rust-analyzer", "rustdoc", "rustfmt", "src"]
docs = false
optimized-compiler-builtins = false
locked-deps = true

[install]
prefix = "$prefix"
sysconfdir = "etc"

[rust]
channel = "$MOTOR_RUST_CHANNEL"
omit-git-hash = false
deny-warnings = false
incremental = false

[llvm]
download-ci-llvm = false
targets = "X86"
experimental-targets = ""
static-libstdcpp = false

[target.x86_64-unknown-linux-gnu]
llvm-config = "$llvm_bin/llvm-config"

[target.x86_64-unknown-motor]
cc = "$sysroot/bin/motor-clang"
cxx = "$sysroot/bin/motor-clang++"
ar = "$llvm_bin/llvm-ar"
ranlib = "$llvm_bin/llvm-ranlib"
linker = "$sysroot/bin/motor-rust-cc"
EOF
}

# The wrappers live in <toolchain>/lib/rustlib/x86_64-unknown-motor/sysroot/bin
# and find clang, its resource directory, and the sysroot from there, so the
# toolchain works wherever it is installed. The sysroot may still be empty:
# the first bootstrap builds Rust std, whose Motor port contains no C.
toolchain_render_cross_wrapper() {
	local wrapper="$1" clang_major="$2" locate mode=
	[[ "$clang_major" =~ ^[0-9]+$ ]] ||
		toolchain_die "invalid Clang major version: $clang_major" || return
	locate='sysroot="$(dirname "$(dirname "$(readlink -f "$0")")")"
host="${sysroot%/*/*}/x86_64-unknown-linux-gnu"'
	case "$wrapper" in
		motor-clang|motor-clang++)
			[ "$wrapper" != motor-clang++ ] || mode=' --driver-mode=g++'
			cat <<EOF
#!/bin/sh
$locate
exec "\$host/bin/clang"$mode --no-default-config \\
  -resource-dir "\$host/lib/clang/$clang_major" \\
  --sysroot="\$sysroot" -D_GNU_SOURCE -D_DEFAULT_SOURCE \\
  "\$@" --target=x86_64-unknown-motor
EOF
			;;
		motor-rust-cc)
			cat <<EOF
#!/bin/sh
$locate
exec "\$host/bin/clang" --no-default-config \\
  -resource-dir "\$host/lib/clang/$clang_major" \\
  --target=x86_64-unknown-motor --sysroot="\$sysroot" "\$@" \\
  -Wl,--start-group \\
  "\$sysroot/devtools/llvm/lib/crt1.o" \\
  -lmoto_rt_cabi -lc++ -lc++abi -lunwind -lc -lclang_rt.builtins-x86_64 \\
  -Wl,--end-group
EOF
			;;
		*) toolchain_die "unknown cross wrapper: $wrapper" ;;
	esac
}

toolchain_generate_cross_wrappers() {
	local sysroot="$1" clang_major="$2" wrapper output
	mkdir -p "$sysroot/bin" || return
	for wrapper in motor-clang motor-clang++ motor-rust-cc; do
		output="$sysroot/bin/$wrapper"
		toolchain_render_cross_wrapper "$wrapper" "$clang_major" > "$output.tmp" &&
			chmod 0755 "$output.tmp" && mv "$output.tmp" "$output" || {
			rm -f "$output.tmp"
			return 1
		}
	done
}
