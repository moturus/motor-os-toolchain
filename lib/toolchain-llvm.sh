#!/usr/bin/env bash
# The standalone LLVM/Clang that Rust bootstrap links and the C sysroot is
# built with.

toolchain_validate_standalone_llvm() {
	local build="$1" binary library library_files
	local -a binaries=(clang clang++ lld ld.lld llvm-ranlib llvm-readelf llvm-config
		"${MOTOR_RUST_BOOTSTRAP_LLVM_TOOLS[@]}")
	for binary in "${binaries[@]}"; do
		[ -x "$build/bin/$binary" ] ||
			toolchain_die "standalone LLVM lacks $binary: $build" || return
	done
	library_files="$("$build/bin/llvm-config" --link-static --libfiles)" ||
		toolchain_die "standalone llvm-config cannot list static libraries" || return
	[ -n "$library_files" ] ||
		toolchain_die "standalone llvm-config listed no static libraries" || return
	for library in $library_files; do
		[ -f "$library" ] ||
			toolchain_die "standalone LLVM lacks static library: $library" || return
	done
}

toolchain_build_standalone_llvm() {
	local llvm="$1" build="$2"
	cmake -S "$llvm/llvm" -B "$build" \
		-G "$MOTOR_STANDALONE_LLVM_GENERATOR" \
		-DCMAKE_BUILD_TYPE="$MOTOR_STANDALONE_LLVM_BUILD_TYPE" \
		-DLLVM_ENABLE_ASSERTIONS="$MOTOR_STANDALONE_LLVM_ASSERTIONS" \
		-DLLVM_ENABLE_PROJECTS="$MOTOR_STANDALONE_LLVM_PROJECTS" \
		-DLLVM_TARGETS_TO_BUILD="$MOTOR_LLVM_TARGETS" \
		-DLLVM_INCLUDE_TESTS="$MOTOR_STANDALONE_LLVM_INCLUDE_TESTS" \
		-DCMAKE_C_COMPILER="$MOTOR_STANDALONE_LLVM_C_COMPILER" \
		-DCMAKE_CXX_COMPILER="$MOTOR_STANDALONE_LLVM_CXX_COMPILER" || return
	ninja -C "$build" "${MOTOR_STANDALONE_LLVM_NINJA_TARGETS[@]}" || return
	toolchain_validate_standalone_llvm "$build"
}
