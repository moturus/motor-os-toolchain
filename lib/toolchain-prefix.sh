#!/usr/bin/env bash
# Validation of the installed Linux-host toolchain.

toolchain_validate_rust_analyzer_version() {
	local output="$1" name="$2" expected_prefix detail hash
	expected_prefix="$name $RUST_VERSION-$MOTOR_RUST_CHANNEL ("
	case "$output" in
		"$expected_prefix"*) ;;
		*) toolchain_die "$name reports the wrong release: $output"; return ;;
	esac
	detail="${output#"$expected_prefix"}"
	hash="${detail%% *}"
	[ -n "$hash" ] && [ "$detail" != "$hash" ] ||
		toolchain_die "$name reports no commit: $output" || return
	case "$RUST_REV" in
		"$hash"*) ;;
		*) toolchain_die "$name reports the wrong commit: $hash" ;;
	esac
}

toolchain_validate_rust_lld() {
	local prefix="$1" source destination
	source="$STANDALONE_LLVM_BIN/lld"
	destination="$prefix/lib/rustlib/x86_64-unknown-linux-gnu/bin/rust-lld"
	[ -f "$destination" ] && [ ! -L "$destination" ] && [ -x "$destination" ] ||
		toolchain_die "installed toolchain lacks rust-lld: $destination" || return
	cmp -s "$source" "$destination" ||
		toolchain_die "installed rust-lld differs from standalone lld" || return
}

toolchain_validate_prefix() {
	local prefix="$1" binary target probe proc_macro_srv
	for binary in rustc rustdoc cargo cargo-clippy clippy-driver cargo-fmt rustfmt \
		rust-analyzer; do
		[ -x "$prefix/bin/$binary" ] ||
			toolchain_die "installed toolchain lacks $binary: $prefix" || return
	done
	[ -f "$prefix/bin/rust-analyzer" ] ||
		toolchain_die "installed rust-analyzer is not a regular file: $prefix" || return
	proc_macro_srv="$prefix/libexec/rust-analyzer-proc-macro-srv"
	[ -f "$proc_macro_srv" ] && [ -x "$proc_macro_srv" ] ||
		toolchain_die "installed toolchain lacks rust-analyzer-proc-macro-srv: $prefix" || return
	[ "$(readlink -f "$proc_macro_srv")" = \
		"$(readlink -f "$prefix")/libexec/rust-analyzer-proc-macro-srv" ] ||
		toolchain_die "installed proc-macro server resolves outside the prefix" || return
	[ -d "$prefix/lib/rustlib/src/rust/library" ] ||
		toolchain_die "installed toolchain lacks rust-src: $prefix" || return
	toolchain_validate_rust_lld "$prefix" || return
	for target in x86_64-unknown-linux-gnu x86_64-unknown-motor; do
		[ -n "$(find "$prefix/lib/rustlib/$target/lib" -maxdepth 1 \
			-type f -name 'libcore-*.rlib' -print -quit 2>/dev/null)" ] ||
			toolchain_die "installed toolchain lacks core for $target" || return
		[ -n "$(find "$prefix/lib/rustlib/$target/lib" -maxdepth 1 \
			-type f -name 'libstd-*.rlib' -print -quit 2>/dev/null)" ] ||
			toolchain_die "installed toolchain lacks std for $target" || return
	done

	VALIDATED_RUSTC_VERBOSE="$("$prefix/bin/rustc" -vV)" || return
	grep -Fqx "commit-hash: $RUST_REV" \
		<<< "$VALIDATED_RUSTC_VERBOSE" ||
		toolchain_die "installed rustc reports the wrong commit" || return
	grep -Fq "($TOOLCHAIN_NAME)" <<< "$VALIDATED_RUSTC_VERBOSE" ||
		toolchain_die "installed rustc does not name $TOOLCHAIN_NAME" || return
	VALIDATED_CARGO_VERBOSE="$("$prefix/bin/cargo" -Vv)" || return
	grep -Fqx "release: $RUST_VERSION-$MOTOR_RUST_CHANNEL" \
		<<< "$VALIDATED_CARGO_VERBOSE" ||
		toolchain_die "installed Cargo reports the wrong version" || return
	grep -Fqx "commit-hash: $CARGO_REV" \
		<<< "$VALIDATED_CARGO_VERBOSE" ||
		toolchain_die "installed Cargo reports the wrong commit" || return
	"$prefix/bin/rustdoc" --version > /dev/null || return
	"$prefix/bin/clippy-driver" --version > /dev/null || return
	"$prefix/bin/rustfmt" --version > /dev/null || return
	VALIDATED_RUST_ANALYZER_VERSION="$("$prefix/bin/rust-analyzer" --version)" || return
	toolchain_validate_rust_analyzer_version \
		"$VALIDATED_RUST_ANALYZER_VERSION" rust-analyzer || return
	toolchain_validate_rust_analyzer_version "$(
		RUST_ANALYZER_INTERNALS_DO_NOT_USE='this is unstable' \
			"$proc_macro_srv" --version
	)" rust-analyzer-proc-macro-srv || return
	[ "$(readlink -f "$("$prefix/bin/rustc" --print sysroot)")" = "$(readlink -f "$prefix")" ] ||
		toolchain_die "installed rustc reports a different sysroot" || return

	probe="$(mktemp -d)"
	printf 'pub fn motor_toolchain_probe() {}\n' > "$probe/probe.rs"
	for target in x86_64-unknown-linux-gnu x86_64-unknown-motor; do
		if ! "$prefix/bin/rustc" --crate-type rlib --target "$target" \
			-o "$probe/probe-$target.rlib" "$probe/probe.rs"; then
			rm -rf "$probe"
			toolchain_die "installed rustc cannot compile for $target"
			return 1
		fi
		[ -f "$probe/probe-$target.rlib" ] || {
			rm -rf "$probe"
			toolchain_die "installed rustc produced no probe for $target"
			return 1
		}
	done
	rm -rf "$probe"
}
