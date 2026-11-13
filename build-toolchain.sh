#!/usr/bin/env bash
#
# build-toolchain.sh — build one release of the Motor OS toolchain and
# package it: the Linux-host cross toolchain (rustc, Cargo, Clang, LLD, the
# host and Motor standard libraries, and the C/C++ sysroot) and the native
# Motor OS toolchain overlays (rustc, rustfmt, clippy-driver, rust-analyzer,
# the LLVM multicall, headers, and libraries).
#
# The sources are the moturus forks of Rust (with its LLVM and Cargo gitlinks)
# and mlibc at the heads of the branches versions.sh names, the Motor runtime
# crates from crates.io, and Motor OS for the development programs. --motor-os
# selects an existing Motor OS checkout instead of cloning it into build/.
#
# Every run starts from nothing: it fetches the sources into build/, builds
# everything there, writes the two archives and their checksums next to this
# checkout, and removes build/.

set -euo pipefail

log()  { printf '\033[1;34m[build-toolchain]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build-toolchain]\033[0m WARNING: %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build-toolchain]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }
trap 'die "failed at line $LINENO"' ERR

usage() {
	cat << 'EOF'
Usage: ./build-toolchain.sh [--provision] [--dev] [--motor-os PATH]

Build the Motor toolchain that versions.sh names, x86_64-unknown-motor-<Rust
version>, and write next to this checkout (into its parent directory):
  motor-toolchain-<name>-x86_64-linux.tar.zst  the Linux-host toolchain
  motor-toolchain-<name>.tar.zst               the native Motor OS toolchain
and a .sha256 checksum file for each.

  --provision  install missing host packages (with sudo) and rustup first
  --dev        name the toolchain <name>-dev: a local build, not a release
  --motor-os PATH
               build development programs from this checkout instead of cloning

The build fetches sources and crates from the network, works in build/, and
removes it when done; a failed build leaves it for inspection.
EOF
}

parse_options() {
	PROVISION=false
	DEV=false
	MOTOR_SOURCE=
	while [ "$#" -gt 0 ]; do
		case "$1" in
			-h|--help) usage; return 2 ;;
			--provision) PROVISION=true; shift ;;
			--dev) DEV=true; shift ;;
			--motor-os)
				[ "$#" -ge 2 ] || die '--motor-os requires a checkout path'
				MOTOR_SOURCE="$(realpath -e "$2")" || die "Motor OS checkout is missing: $2"
				[ -e "$MOTOR_SOURCE/.git" ] && [ -f "$MOTOR_SOURCE/src/build-motor-os.sh" ] ||
					die "not a Motor OS checkout: $MOTOR_SOURCE"
				case "$MOTOR_SOURCE/" in
					"$WORK/"*) die '--motor-os must be outside the disposable build directory' ;;
				esac
				shift 2 ;;
			*) usage >&2; die "unknown argument: $1" ;;
		esac
	done
}

TOOLCHAIN_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
. "$TOOLCHAIN_ROOT/versions.sh"
. "$TOOLCHAIN_ROOT/patches/crates.sh"
for helper in lib llvm bootstrap prefix host rust-analyzer patched-crates \
	native native-rust-analyzer package; do
	. "$TOOLCHAIN_ROOT/lib/toolchain-$helper.sh"
done

TARGET=x86_64-unknown-motor

# On-image directory prefixes (mirrored inside the cross sysroot). Keep these in
# sync with clang/lib/Driver/ToolChains/Motor.cpp and mlibc's MLIBC_SYSCONFDIR.
TOOLS="user/lib/llvm"              # headers + libraries
CFG_LLVM="user/lib/llvm/cfg"       # clang <triple>.cfg
CFG_LIBC="system/cfg/libc"         # mlibc config files (resolv.conf, ...)

# Everything a build reads and writes, besides Cargo's and rustup's caches.
WORK="$TOOLCHAIN_ROOT/build"
RUST="$WORK/rust"
LLVM="$RUST/src/llvm-project"
MLIBC="$WORK/mlibc"
TAR_SOURCE="$WORK/motor-os-tar"
TOOLCHAIN_PREFIX="$WORK/toolchain"
TOOLCHAIN_IMAGES="$WORK/images"
SYSROOT="$TOOLCHAIN_PREFIX/lib/rustlib/$TARGET/sysroot"
STANDALONE_LLVM_BUILD="$WORK/llvm"
STANDALONE_LLVM_BIN="$STANDALONE_LLVM_BUILD/bin"
B="$STANDALONE_LLVM_BIN"            # the compilers and tools of the C stages
RUST_BUILD_DIR="$WORK/rust-build"
BOOTSTRAP_CACHE="$WORK/bootstrap-cache"
CROSS_FILE="$WORK/motor.cross-file"
SHIM_TARGET_DIR="$WORK/moto-rt-cabi"
BUILTINS_BUILD="$WORK/compiler-rt-builtins"
MLIBC_HEADERS_BUILD="$WORK/mlibc-headers"
MLIBC_BUILD="$WORK/mlibc-build"
CXX_BUILD="$WORK/libcxx"
NATIVE_LLVM_BUILD="$WORK/native-llvm"
LLVM_IMG="$TOOLCHAIN_IMAGES/llvm"
RUSTC_IMG="$TOOLCHAIN_IMAGES/rustc"
LIBC_IMG="$TOOLCHAIN_IMAGES/libc"
MOTOR_CARGO="$TOOLCHAIN_PREFIX/bin/cargo"
MOTOR_RUSTC="$TOOLCHAIN_PREFIX/bin/rustc"
MOTOR_RUSTDOC="$TOOLCHAIN_PREFIX/bin/rustdoc"
RUSTLIB_SRC="$TOOLCHAIN_PREFIX/lib/rustlib/$TARGET/lib"

run_motor_cargo() {
	RUSTC="$MOTOR_RUSTC" RUSTDOC="$MOTOR_RUSTDOC" "$MOTOR_CARGO" "$@"
}

# --- provisioning: everything that needs sudo happens first --------------------
PACKAGES=(git build-essential clang cmake ninja-build meson python3 \
	zlib1g-dev libssl-dev pkg-config curl)

provision_host() {
	log "provisioning: checking required host packages and rustup"
	if ! command -v apt-get >/dev/null 2>&1; then
		warn "apt-get not found; install these packages yourself: ${PACKAGES[*]}"
	else
		local missing=() package
		for package in "${PACKAGES[@]}"; do
			dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
				grep -q 'install ok installed' || missing+=("$package")
		done
		if [ "${#missing[@]}" -gt 0 ]; then
			log "installing missing host packages: ${missing[*]}"
			sudo apt-get update
			# sudo DEBIAN_FRONTEND=noninteractive apt-get -y install "${missing[@]}"
			sudo apt-get -y install "${missing[@]}"
		else
			log "all required host packages are already installed"
		fi
	fi
	[ ! -f "$HOME/.cargo/env" ] || . "$HOME/.cargo/env"
	if ! command -v rustup >/dev/null 2>&1; then
		log "installing rustup without a default toolchain"
		curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
			sh -s -- -y --default-toolchain none
		. "$HOME/.cargo/env"
	else
		log "rustup is already installed ($(command -v rustup))"
	fi
}

# --- stage 1/12: the sources ---------------------------------------------------
# Bootstrap does not update submodules (submodules = false); these are the ones
# it needs besides LLVM, whose repository versions.sh selects explicitly.
RUST_SUBMODULES=(src/tools/cargo library/backtrace src/doc/book
	src/doc/reference src/tools/rustc-perf)

fetch_sources() {
	log "stage 1/12: fetching the sources"
	toolchain_fetch_branch "$MOTOR_RUST_REPOSITORY" "$MOTOR_RUST_BRANCH" "$RUST"
	log "fetching LLVM submodule ($MOTOR_LLVM_REPOSITORY) into build/rust/src/llvm-project"
	git -C "$RUST" config submodule.src/llvm-project.url "$MOTOR_LLVM_REPOSITORY"
	# Permit local LLVM checkouts only for this explicitly configured submodule.
	git -C "$RUST" -c protocol.file.allow=always submodule update --init --depth 1 src/llvm-project
	log "fetching Rust submodules (${RUST_SUBMODULES[*]})"
	git -C "$RUST" submodule update --init --depth 1 "${RUST_SUBMODULES[@]}"
	toolchain_fetch_branch "$MOTOR_MLIBC_REPOSITORY" "$MOTOR_MLIBC_BRANCH" "$MLIBC"
	toolchain_fetch_branch "$MOTOR_TAR_REPOSITORY" "$MOTOR_TAR_BRANCH" "$TAR_SOURCE"
	fetch_motor_source
	RUST_VERSION="$(cat "$RUST/src/version")"
	RUST_REV="$(git -C "$RUST" rev-parse HEAD)"
	LLVM_REV="$(git -C "$LLVM" rev-parse HEAD)"
	CARGO_REV="$(git -C "$RUST/src/tools/cargo" rev-parse HEAD)"
	MLIBC_REV="$(git -C "$MLIBC" rev-parse HEAD)"
	TOOLCHAIN_NAME="$(toolchain_name "$RUST" "$MOTOR_TOOLCHAIN_RELEASE" "$DEV")"
}

fetch_motor_source() {
	if [ -z "$MOTOR_SOURCE" ]; then
		MOTOR_SOURCE="$WORK/motor-os"
		toolchain_fetch_branch "$MOTOR_OS_REPOSITORY" "$MOTOR_OS_BRANCH" "$MOTOR_SOURCE"
	fi
}

build_motor_tools() {
	log "building the development programs from $MOTOR_SOURCE"
	bash "$MOTOR_SOURCE/src/build-motor-os.sh" --toolchain-overlays "$TOOLCHAIN_PREFIX" "$TOOLCHAIN_IMAGES"
}

# The C stages compile and link with the standalone Clang and name the runtimes
# themselves; Clang loads this file for --target=x86_64-unknown-motor, so its
# Motor driver adds none of its own. The shipped wrappers pass
# --no-default-config.
configure_cross_driver() {
	cat > "$B/x86_64-unknown-motor.cfg" <<'EOF'
-fuse-ld=lld
-static-pie
-nostdlib
-Wl,-e,motor_start
-Wl,--pack-dyn-relocs=none
-Wl,-z,noexecstack
EOF
}

# ============================================================================
# The C/C++ sysroot (mlibc + libc++ stack) inside the host toolchain, and the
# native LLVM/Clang, staged into the overlays.
# ============================================================================

# --- stage 3/12: the C-ABI shim (libmoto_rt_cabi.a) ----------------------------
build_shim() {
	log "stage 3/12: building the moto-rt-cabi shim"
	local rustlibs=("$RUSTLIB_SRC"/*.rlib) symbol
	for symbol in motor_start memcpy memmove memset memcmp; do
		if "$B/llvm-nm" --defined-only "${rustlibs[@]}" 2>/dev/null |
				awk -v symbol="$symbol" '$2 ~ /^[Tt]$/ && $3 == symbol { found = 1 } END { exit !found }'; then
			die "Motor target libraries define strong $symbol; mixed Rust+C links are unsafe"
		fi
	done
	mkdir -p "$SYSROOT/$TOOLS/lib" "$SYSROOT/$TOOLS/include"
	( cd "$MLIBC/sysdeps/motor/moto-rt-cabi" \
		&& run_motor_cargo fetch --locked \
		&& CARGO_TARGET_DIR="$SHIM_TARGET_DIR" \
		run_motor_cargo build --locked --offline --target x86_64-unknown-motor --release \
			-Zbuild-std=core,alloc )
	cp "$SHIM_TARGET_DIR/x86_64-unknown-motor/release/libmoto_rt_cabi.a" \
		"$SYSROOT/$TOOLS/lib/"
	if "$B/llvm-nm" "$SYSROOT/$TOOLS/lib/libmoto_rt_cabi.a" 2>/dev/null |
			awk '$NF == "rust_eh_personality" ||
				$NF == "DW.ref.rust_eh_personality" ||
				$NF ~ /^_Unwind_/ || $NF ~ /^__unw_/ { found = 1 }
				END { exit !found }'; then
		die "moto-rt-cabi contains unwind runtime references"
	fi
	for symbol in motor_start memcpy memmove memset memcmp; do
		if "$B/llvm-nm" --defined-only \
				"$SYSROOT/$TOOLS/lib/libmoto_rt_cabi.a" 2>/dev/null |
				awk -v symbol="$symbol" '$2 ~ /^[Tt]$/ && $3 == symbol { found = 1 } END { exit !found }'; then
			die "moto-rt-cabi defines strong $symbol; mixed Rust+C links are unsafe"
		fi
	done
	cp "$MLIBC/sysdeps/motor/moto-rt-cabi/moto_rt.h" "$SYSROOT/$TOOLS/include/"
}

# --- stage 4/12: compiler-rt builtins (emutls excluded) ------------------------
build_builtins() {
	log "stage 4/12: building compiler-rt builtins"
	# -ffreestanding: the builtins are freestanding, and it keeps clang's
	# resource limits.h/stdint.h from #include_next-ing into the host's glibc
	# headers. The Motor ToolChain adds <sysroot>/user/lib/llvm/include, which
	# is empty under the cross sysroot at this stage (mlibc's headers do not
	# exist yet). (The old host cfg used to supply -ffreestanding here.)
	#
	# CMAKE_DISABLE_FIND_PACKAGE_LLVM=ON: the standalone builtins build calls a
	# non-REQUIRED find_package(LLVM) (compiler-rt/.../CompilerRTUtils.cmake,
	# load_llvm_config). With no hint it searches system paths and, on a host
	# that has a distro LLVM -dev package installed (e.g. /usr/lib/llvm-21),
	# loads that package's LLVMExports.cmake — which declares the libLLVM/LTO/
	# Remarks dylibs as `SHARED IMPORTED`. Under CMAKE_SYSTEM_NAME=Generic the
	# platform has no dynamic linking, and newer CMake makes an imported SHARED
	# target a hard error ("... target platform does not support dynamic
	# linking"), aborting the configure. The builtins don't need LLVM at all:
	# disabling the lookup forces compiler-rt's built-in mock-config fallback,
	# which is the same path taken on a host with no system LLVM. (Pointing at
	# the freshly built build tree would not help — its exports carry the same
	# SHARED-imported LTO/Remarks targets.)
	cmake -S "$LLVM/compiler-rt/lib/builtins" -B "$BUILTINS_BUILD" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_SYSTEM_NAME=Generic \
		-DCMAKE_SYSTEM_PROCESSOR=x86_64 \
		-DCMAKE_C_FLAGS="-ffreestanding" \
		-DCMAKE_C_COMPILER="$B/clang" \
		-DCMAKE_C_COMPILER_TARGET=x86_64-unknown-motor \
		-DCMAKE_ASM_COMPILER="$B/clang" \
		-DCMAKE_ASM_COMPILER_TARGET=x86_64-unknown-motor \
		-DCMAKE_AR="$B/llvm-ar" -DCMAKE_RANLIB="$B/llvm-ranlib" -DCMAKE_NM="$B/llvm-nm" \
		-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
		-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
		-DCOMPILER_RT_BAREMETAL_BUILD=ON \
		-DCMAKE_DISABLE_FIND_PACKAGE_LLVM=ON
	ninja -C "$BUILTINS_BUILD"

	local builtins
	builtins="$(find "$BUILTINS_BUILD" -name 'libclang_rt.builtins*.a' | head -1)"
	[ -n "$builtins" ] || die "builtins archive not produced"

	# emutls.c must not be present (the shim owns emulated TLS).
	if "$B/llvm-ar" t "$builtins" | grep -q emutls; then
		"$B/llvm-ar" d "$builtins" emutls.c.o
	fi
	if "$B/llvm-nm" "$builtins" 2>/dev/null | grep -q __emutls; then
		warn "__emutls_* still present in builtins — expected it excluded"
	fi

	# Stage a copy in the sysroot and one at the per-target resource-dir path
	# where both mlibc's build and the clang driver look for it, for the
	# standalone clang of the C stages and for the toolchain's own.
	cp "$builtins" "$SYSROOT/$TOOLS/lib/libclang_rt.builtins-x86_64.a"
	local rd
	for rd in "$STANDALONE_LLVM_BUILD/lib/clang/$CLANG_MAJOR" \
		"$TOOLCHAIN_PREFIX/lib/rustlib/x86_64-unknown-linux-gnu/lib/clang/$CLANG_MAJOR"; do
		mkdir -p "$rd/lib/x86_64-unknown-motor"
		cp "$builtins" "$rd/lib/x86_64-unknown-motor/libclang_rt.builtins.a"
	done
}

# --- stage 5/12: mlibc ---------------------------------------------------------
build_mlibc() {
	log "stage 5/12: building mlibc"
	# Meson cross file with this machine's absolute paths (kept out of the repos).
	# MLIBC_SYSCONFDIR repoints mlibc's runtime config lookups (resolv.conf,
	# hosts, passwd, ...) from /etc to /system/cfg/libc.
	cat > "$CROSS_FILE" << EOF
[binaries]
c = ['$B/clang', '--target=x86_64-unknown-motor']
cpp = ['$B/clang++', '--target=x86_64-unknown-motor']
ar = '$B/llvm-ar'
strip = '$B/llvm-strip'

[host_machine]
system = 'motor'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[built-in options]
c_args = ['-I$SYSROOT/$TOOLS/include', '-D_GNU_SOURCE', '-DMLIBC_SYSCONFDIR="/$CFG_LIBC"']
cpp_args = ['-I$SYSROOT/$TOOLS/include', '-D_GNU_SOURCE', '-DMLIBC_SYSCONFDIR="/$CFG_LIBC"']

[properties]
needs_exe_wrapper = true
EOF

	( cd "$MLIBC"
		setup_mlibc_build() {
			meson setup --cross-file "$CROSS_FILE" --prefix="/$TOOLS" "$@"
		}

		# Headers first (validates ABI/meson wiring quickly).
		log "installing mlibc headers into sysroot"
		setup_mlibc_build -Dheaders_only=true "$MLIBC_HEADERS_BUILD"
		DESTDIR="$SYSROOT" ninja -C "$MLIBC_HEADERS_BUILD" install

		# The real static build: libc.a, crt1.o, headers, companion stubs.
		# -Ddebug=false: mlibc's meson.build pins buildtype=debugoptimized
		# (-O2 -g); the flag keeps -O2 and drops only -g. Without it libc.a is
		# 18 MB (59% DWARF) and every mlibc-linked binary carries ~6.6 MB of
		# debug info (see docs/libc_start_redesign.md). .text is byte-identical.
		log "building and installing static mlibc"
		setup_mlibc_build -Ddefault_library=static -Dbuild_tests=false -Ddebug=false \
			"$MLIBC_BUILD"
		ninja -C "$MLIBC_BUILD"
		DESTDIR="$SYSROOT" ninja -C "$MLIBC_BUILD" install )

	ls "$SYSROOT/$TOOLS/lib/libc.a" "$SYSROOT/$TOOLS/lib/crt1.o" >/dev/null
}

# --- stage 6/12: the C++ runtime stack (with exceptions) -----------------------
build_cxx_runtimes() {
	log "stage 6/12: building libunwind + libc++abi + libc++ (exceptions on)"
	cmake -G Ninja -S "$LLVM/runtimes" -B "$CXX_BUILD" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_C_COMPILER="$B/clang" -DCMAKE_CXX_COMPILER="$B/clang++" \
		-DCMAKE_C_COMPILER_TARGET=x86_64-unknown-motor \
		-DCMAKE_CXX_COMPILER_TARGET=x86_64-unknown-motor \
		-DCMAKE_SYSTEM_NAME=Generic \
		-DCMAKE_SYSROOT="$SYSROOT" \
		-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
		-DCMAKE_C_FLAGS="-isystem $SYSROOT/$TOOLS/include -D_GNU_SOURCE -D_DEFAULT_SOURCE -D_LIBUNWIND_USE_DLADDR=0" \
		-DCMAKE_CXX_FLAGS="-isystem $SYSROOT/$TOOLS/include -D_GNU_SOURCE -D_DEFAULT_SOURCE -D_LIBUNWIND_USE_DLADDR=0" \
		-DCMAKE_INSTALL_PREFIX="/$TOOLS" \
		-DLLVM_ENABLE_RUNTIMES="libunwind;libcxxabi;libcxx" \
		-DLLVM_USE_LINKER=lld \
		-DLIBUNWIND_ENABLE_SHARED=OFF -DLIBUNWIND_ENABLE_STATIC=ON \
		-DLIBUNWIND_ENABLE_THREADS=ON \
		-DLIBUNWIND_USE_COMPILER_RT=ON \
		-DLIBUNWIND_INCLUDE_TESTS=OFF \
		-DLIBUNWIND_HAS_PTHREAD_LIB=OFF -DLIBUNWIND_HAS_DL_LIB=OFF \
		-DLIBCXXABI_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_STATIC=ON \
		-DLIBCXXABI_ENABLE_EXCEPTIONS=ON \
		-DLIBCXXABI_ENABLE_THREADS=ON \
		-DLIBCXXABI_USE_COMPILER_RT=ON \
		-DLIBCXXABI_USE_LLVM_UNWINDER=ON \
		-DLIBCXXABI_HAS_CXA_THREAD_ATEXIT_IMPL=OFF \
		-DLIBCXXABI_ENABLE_ASSERTIONS=OFF \
		-DLIBCXXABI_HAS_PTHREAD_LIB=OFF \
		-DLIBCXX_ENABLE_SHARED=OFF -DLIBCXX_ENABLE_STATIC=ON \
		-DLIBCXX_ENABLE_EXCEPTIONS=ON -DLIBCXX_ENABLE_RTTI=ON \
		-DLIBCXX_ENABLE_THREADS=ON -DLIBCXX_HAS_PTHREAD_API=ON \
		-DLIBCXX_ENABLE_MONOTONIC_CLOCK=ON \
		-DLIBCXX_ENABLE_RANDOM_DEVICE=ON \
		-DLIBCXX_ENABLE_WIDE_CHARACTERS=ON \
		-DLIBCXX_ENABLE_LOCALIZATION=ON \
		-DLIBCXX_ENABLE_FILESYSTEM=ON \
		-DLIBCXX_CXX_ABI=libcxxabi \
		-DLIBCXX_USE_COMPILER_RT=ON \
		-DLIBCXX_HAS_PTHREAD_LIB=OFF -DLIBCXX_HAS_RT_LIB=OFF \
		-DLIBCXX_HAS_ATOMIC_LIB=OFF \
		-DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXX_INCLUDE_TESTS=OFF
	ninja -C "$CXX_BUILD" unwind cxxabi cxx
	DESTDIR="$SYSROOT" ninja -C "$CXX_BUILD" \
		install-unwind install-cxxabi install-cxx

	ls "$SYSROOT/$TOOLS/lib/libc++.a" "$SYSROOT/$TOOLS/lib/libc++abi.a" \
		"$SYSROOT/$TOOLS/lib/libunwind.a" >/dev/null
}

# --- stage 7/12: the native LLVM toolchain (the on-image `llvm`) ---------------
build_native_llvm() {
	log "stage 7/12: building the native (on-image) LLVM toolchain"
	# The STANDARD_LIBRARIES mirror the Motor ToolChain's link group (shim first
	# so its __cxa_thread_atexit wins; -lunwind for the EH runtime). Both the C
	# and C++ groups carry -lc++abi: mlibc is implemented in C++, so even a C link
	# pulls `operator delete`/`new` from libc.a members (this matches the Motor
	# ToolChain's ConstructJob, which adds -lc++abi unconditionally).
	cmake -S "$LLVM/llvm" -B "$NATIVE_LLVM_BUILD" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_SYSTEM_NAME=Linux \
		-DCMAKE_SYSROOT="$SYSROOT" \
		-DCMAKE_C_COMPILER="$B/clang" \
		-DCMAKE_CXX_COMPILER="$B/clang++" \
		-DCMAKE_C_COMPILER_TARGET=x86_64-unknown-motor \
		-DCMAKE_CXX_COMPILER_TARGET=x86_64-unknown-motor \
		-DCMAKE_C_FLAGS="-isystem $SYSROOT/$TOOLS/include -D_GNU_SOURCE -D_DEFAULT_SOURCE" \
		-DCMAKE_CXX_FLAGS="-nostdinc++ -isystem $SYSROOT/$TOOLS/include/c++/v1 -isystem $SYSROOT/$TOOLS/include -D_GNU_SOURCE -D_DEFAULT_SOURCE" \
		-DCMAKE_C_STANDARD_LIBRARIES="$SYSROOT/$TOOLS/lib/crt1.o -Wl,--start-group -lmoto_rt_cabi -lc++abi -lunwind -lc -lclang_rt.builtins-x86_64 -Wl,--end-group" \
		-DCMAKE_CXX_STANDARD_LIBRARIES="$SYSROOT/$TOOLS/lib/crt1.o -Wl,--start-group -lmoto_rt_cabi -lc++ -lc++abi -lunwind -lc -lclang_rt.builtins-x86_64 -Wl,--end-group" \
		-DCMAKE_EXE_LINKER_FLAGS="-L$SYSROOT/$TOOLS/lib" \
		-DCMAKE_TRY_COMPILE_PLATFORM_VARIABLES="CMAKE_C_STANDARD_LIBRARIES;CMAKE_CXX_STANDARD_LIBRARIES" \
		-DLLVM_HOST_TRIPLE=x86_64-unknown-motor \
		-DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-unknown-motor \
		-DLLVM_TARGETS_TO_BUILD=X86 \
		-DLLVM_ENABLE_PROJECTS="clang;lld" \
		-DLLVM_TOOL_LLVM_DRIVER_BUILD=ON \
		-DLLVM_NATIVE_TOOL_DIR="$B" \
		-DLLVM_ENABLE_THREADS=ON \
		-DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF \
		-DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_PLUGINS=OFF \
		-DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
		-DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
		-DCLANG_ENABLE_STATIC_ANALYZER=OFF \
		-DCLANG_DEFAULT_LINKER=lld -DCLANG_DEFAULT_RTLIB=compiler-rt \
		-DCLANG_DEFAULT_CXX_STDLIB=libc++ \
		-DDEFAULT_SYSROOT= \
		-DCLANG_CONFIG_FILE_SYSTEM_DIR="/$CFG_LLVM"

	ninja -C "$NATIVE_LLVM_BUILD" llvm-driver
}

# --- stage 8/12: stage the C/C++ toolchain into the image ----------------------
llvm_stage_image() {
	log "stage 8/12: staging the C/C++ toolchain and libc configuration into the overlays"
	local img="$LLVM_IMG"
	mkdir -p "$img/user/bin/dev" "$img/none/dev/hello-world" \
		"$img/$TOOLS/bin" "$img/$TOOLS/lib" \
		"$img/$CFG_LLVM" "$LIBC_IMG/$CFG_LIBC"

	# Headers: mlibc + libc++'s c++/v1.
	cp -a "$SYSROOT/$TOOLS/include" "$img/$TOOLS/include"

	# Clang's own resource headers (intrinsics, stdarg.h, ...).
	mkdir -p "$img/$TOOLS/lib/clang/$CLANG_MAJOR"
	cp -a "$STANDALONE_LLVM_BUILD/lib/clang/$CLANG_MAJOR/include" \
		"$img/$TOOLS/lib/clang/$CLANG_MAJOR/include"

	# Libraries — strip debug info on the way in.
	local a
	for a in libc libc++ libc++abi libunwind libmoto_rt_cabi \
	         libclang_rt.builtins-x86_64 \
	         libdl libm libpthread librt libresolv libutil libssp libssp_nonshared; do
		"$B/llvm-objcopy" --strip-debug "$SYSROOT/$TOOLS/lib/$a.a" "$img/$TOOLS/lib/$a.a"
	done
	cp "$SYSROOT/$TOOLS/lib/crt1.o" "$img/$TOOLS/lib/"

	# The on-image LLVM multicall lives under /user/lib/llvm/bin, mirroring the
	# Rust toolchain at /user/lib/rust/bin (build-rustc.md). Its clang config and
	# resource dir are pinned by absolute path (the /user/lib/llvm/cfg .cfg + the baked
	# CLANG_CONFIG_FILE_SYSTEM_DIR), and its ld.lld self-dispatch uses the running
	# exe's own path, so the binary works wherever it is placed.
	"$B/llvm-strip" -o "$img/$TOOLS/bin/llvm" "$NATIVE_LLVM_BUILD/bin/llvm"

	# /user/bin/dev/cc — the C compiler / linker driver: a Rush script (not
	# a compiled binary) over the llvm multicall's clang. rustc's default linker
	# is the bare name `cc`, resolved through the dev image PATH, so a native
	# `rustc hello.rs -o hello` links with no `-C linker=` flag — exactly as rustc
	# uses /usr/bin/cc on Linux. A pure pass-through: the Motor clang ToolChain
	# owns the whole link recipe (crt1.o + the mlibc/libc++ group, incl. libc++abi
	# for C links) and gates it on -nostdlib/-nostartfiles/-nodefaultlibs, so a
	# plain `cc hello.c` gets the full C runtime while rustc's pure-Rust links
	# (which pass -nostartfiles -nodefaultlibs) get nothing forced on them — a
	# pure-Rust hello is ~113 KB, not 8 MB (docs/libc_start_redesign.md). Rust
	# programs that *want* mlibc opt back into the ToolChain recipe with
	# `-C link-self-contained=no -C default-linker-libraries=yes` (build-rustc.md).
	cat > "$img/user/bin/dev/cc" << 'EOF'
#!/user/bin/rush
# cc — Motor OS's system C compiler / linker driver. See docs/build-llvm.md.
# A pass-through: clang's Motor ToolChain owns the link recipe and honors
# -nostartfiles/-nodefaultlibs (rustc's pure-Rust links stay mlibc-free).
exec /user/lib/llvm/bin/llvm clang "$@"
EOF

	# /user/bin/dev/c++ — same, in C++ driver mode (adds -lc++ at link).
	# rather than a `clang++` subcommand: the multicall dispatches on the first
	# argument, and `clang++` is not a registered subcommand name.
	cat > "$img/user/bin/dev/c++" << 'EOF'
#!/user/bin/rush
# c++ — Motor OS's system C++ compiler / linker driver. See docs/build-llvm.md.
exec /user/lib/llvm/bin/llvm clang --driver-mode=g++ "$@"
EOF
	cat > "$img/user/bin/dev/ar" << 'EOF'
#!/user/bin/rush
exec /user/lib/llvm/bin/llvm ar "$@"
EOF
	chmod +x "$img/user/bin/dev/cc" "$img/user/bin/dev/c++" "$img/user/bin/dev/ar"

	# The image driver config: only the resource dir needs pinning (the full
	# link/include recipe lives in the Motor ToolChain now). Clang auto-loads it
	# from /user/lib/llvm/cfg (CLANG_CONFIG_FILE_SYSTEM_DIR, stage 7).
	cat > "$img/$CFG_LLVM/x86_64-unknown-motor.cfg" << EOF
-resource-dir /$TOOLS/lib/clang/$CLANG_MAJOR
EOF

	# Ship libc's hosts and services databases. sys-io atomically generates
	# resolv.conf from static per-device configuration or active DHCP leases.
	cat > "$LIBC_IMG/$CFG_LIBC/services" << 'EOF'
domain 53/tcp
domain 53/udp
EOF
	cat > "$LIBC_IMG/$CFG_LIBC/hosts" << 'EOF'
127.0.0.1 localhost
::1 localhost
127.0.0.53 motor-dns-test
::1 motor-dns-test
EOF
	cat > "$LIBC_IMG/$CFG_LIBC/shells" << 'EOF'
/user/bin/sh
/user/bin/rush
EOF

	cat > "$img/none/dev/hello-world/hello.c" << 'EOF'
#include <stdio.h>

int main(void) {
	printf("Hello from Motor-native clang!\n");
	return 0;
}
EOF
	cat > "$img/none/dev/hello-world/hello.cpp" << 'EOF'
#include <iostream>
#include <string>
#include <vector>

int main() {
	std::vector<std::string> words{"Hello", "from", "Motor-native", "clang++!"};
	std::string out;
	for (const auto &w : words) {
		if (!out.empty())
			out += ' ';
		out += w;
	}
	std::cout << out << std::endl;
	return 0;
}
EOF
}

# --- stage 10/12: stage rustc + the Rust sysroot into the image ----------------
rustc_stage_image() {
	log "stage 10/12: staging rustc and the Rust sysroot into the rustc overlay"
	local rust_img="$RUSTC_IMG/user/lib/rust"
	mkdir -p "$RUSTC_IMG/user/bin/dev" "$RUSTC_IMG/none/dev/hello-world" "$rust_img/bin" \
		"$rust_img/lib/rustlib/$TARGET"

	# The compiler, stripped (~154 MB -> ~98 MB).
	"$B/llvm-strip" -o "$rust_img/bin/rustc" "$RUSTC_MAIN"
	toolchain_validate_native_elf "$rust_img/bin/rustc" "$B/llvm-readelf" "$RUSTC_MAIN" ||
		die "staged rustc ELF validation failed"
	cat > "$RUSTC_IMG/user/bin/dev/rustc" << 'EOF'
#!/user/bin/rush
exec /user/lib/rust/bin/rustc "$@"
EOF
	chmod +x "$RUSTC_IMG/user/bin/dev/rustc"
	"$B/llvm-strip" -o "$rust_img/bin/rustfmt" "$RUSTFMT_MAIN"
	toolchain_validate_native_elf "$rust_img/bin/rustfmt" "$B/llvm-readelf" "$RUSTFMT_MAIN" ||
		die "staged rustfmt ELF validation failed"
	cat > "$RUSTC_IMG/user/bin/dev/rustfmt" << 'EOF'
#!/user/bin/rush
exec /user/lib/rust/bin/rustfmt "$@"
EOF
	chmod +x "$RUSTC_IMG/user/bin/dev/rustfmt"
	"$B/llvm-strip" -o "$rust_img/bin/clippy-driver" "$CLIPPY_DRIVER_MAIN"
	toolchain_validate_native_clippy_driver "$rust_img/bin/clippy-driver" "$CLIPPY_DRIVER_MAIN" ||
		die "staged clippy-driver validation failed"
	cat > "$RUSTC_IMG/user/bin/dev/clippy-driver" << 'EOF'
#!/user/bin/rush
exec /user/lib/rust/bin/clippy-driver "$@"
EOF
	chmod +x "$RUSTC_IMG/user/bin/dev/clippy-driver"
	# A binary that still carries mlibc's operator-delete panic stub would
	# abort at runtime; the stub guard must have taken effect.
	if grep -aq 'operator delete called! delete expressions' "$rust_img/bin/rustc"; then
		die "staged rustc contains mlibc's operator-delete stub — sysroot libc.a is stale (see docs/build-rustc.md pitfalls)"
	fi

	# The Rust sysroot. Copy the whole lib dir: the rlibs carry only metadata
	# *stubs* (bootstrap uses -Zembed-metadata=no) — the .rmeta siblings and
	# self-contained/ must come along or rustc fails with "only metadata stub
	# found for rlib dependency `std`".
	mkdir -p "$rust_img/lib/rustlib/$TARGET/lib"
	cp -r "$RUSTLIB_SRC"/* "$rust_img/lib/rustlib/$TARGET/lib/"
	[ -n "$(ls "$rust_img/lib/rustlib/$TARGET/lib"/*.rmeta 2>/dev/null)" ] || \
		die "no .rmeta files staged — rustc on the image would reject every rlib"

	# (`cc`, the linker driver rustc uses, is a Rush script staged by the
	# LLVM stage — nothing to stage here.)

	# A sample source exercising HashMap, sorting, and thread spawn/join.
	cat > "$RUSTC_IMG/none/dev/hello-world/hello.rs" << 'EOF'
use std::collections::HashMap;

fn main() {
    let mut m = HashMap::new();
    for (i, w) in "hello from rustc running natively on motor os".split(' ').enumerate() {
        m.insert(w, i);
    }
    let mut kv: Vec<_> = m.into_iter().collect();
    kv.sort_by_key(|&(_, i)| i);
    let words: Vec<&str> = kv.into_iter().map(|(w, _)| w).collect();
    println!("{}", words.join(" "));
    let t = std::thread::spawn(|| (1..=10u64).product::<u64>());
    println!("10! = {}", t.join().unwrap());
}
EOF

}


# --- stage 12/12: the archives -------------------------------------------------
# The Linux tar that writes the archives is built with the new host toolchain.
build_tar() {
	log "stage 12/12: building motor-os-tar's tar and packaging archives"
	run_motor_cargo build --release --locked --manifest-path "$TAR_SOURCE/Cargo.toml" \
		--target-dir "$WORK/motor-os-tar-target" --bin tar
	TAR="$WORK/motor-os-tar-target/release/tar"
}

main() {
	local parse_status=0 out
	parse_options "$@" || parse_status=$?
	[ "$parse_status" -eq 0 ] || {
		[ "$parse_status" -eq 2 ] && return 0
		return "$parse_status"
	}
	[ "$PROVISION" = false ] || provision_host

	if [ -e "$WORK" ]; then
		log "removing previous build directory: $WORK"
		rm -rf "$WORK"
	fi
	mkdir -p "$WORK"
	fetch_sources
	out="$(dirname "$TOOLCHAIN_ROOT")"
	log "building $TOOLCHAIN_NAME"
	log "Rust: $RUST_REV; LLVM: $LLVM_REV; mlibc: $MLIBC_REV"
	export PYTHONDONTWRITEBYTECODE=1

	log "stage 2/12: building the Linux-host toolchain"
	toolchain_build_host "$RUST"
	toolchain_fetch_rust_analyzer "$RUST" "$TOOLCHAIN_PREFIX"
	configure_cross_driver
	build_shim
	build_builtins
	build_mlibc
	build_cxx_runtimes
	build_native_llvm
	llvm_stage_image
	log "stage 9/12: building native rustc, rustfmt, and clippy-driver"
	toolchain_build_native_rustc "$RUST"
	rustc_stage_image
	log "stage 11/12: building and staging native rust-analyzer"
	toolchain_build_native_rust_analyzer "$RUST"
	build_tar
	build_motor_tools
	toolchain_package "$TAR" "$out" "$TOOLCHAIN_NAME" "$TOOLCHAIN_IMAGES" "$TOOLCHAIN_PREFIX"
	log "removing temporary build directory: $WORK"
	rm -rf "$WORK"
	log "built $TOOLCHAIN_NAME in $out"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
