# Motor OS toolchain

`build-toolchain.sh` builds one release of the Motor OS toolchain from the
moturus forks of Rust (with its LLVM and Cargo gitlinks) and mlibc, and
packages it as two archives. A release is named like Rust's own toolchains,
by the target and the Rust version it is based on:
`x86_64-unknown-motor-1.99.1`. That name is what rustup and the Motor OS
checkout know it by. A beta is `x86_64-unknown-motor-1.100.0-beta`; a second
release of the same Rust version, after a Motor-side change, is
`x86_64-unknown-motor-1.99.1-2`. A published release never changes.

The toolchain consists of:

- the Linux-host cross toolchain: rustc, rustdoc, Cargo, Clippy, rustfmt,
  rust-analyzer with its proc-macro server, the host and Motor standard
  libraries, `rust-src`, Clang and LLD with the LLVM tools Motor OS builds
  use, and the C/C++ cross sysroot (mlibc, libc++, libc++abi, libunwind,
  compiler-rt builtins, and the `moto-rt-cabi` shim) with its compiler
  wrappers;
- the native Motor OS toolchain, as the image overlays `llvm`, `rustc`,
  `rust-analyzer`, and `libc`: rustc, rustfmt, clippy-driver, rust-analyzer,
  the LLVM multicall, headers, libraries, and mlibc's configuration.

Nothing is read from a Motor OS checkout.

## Building

On Ubuntu 24.04 or 26.04:

```sh
git clone https://github.com/moturus/motor-os-toolchain.git
cd motor-os-toolchain
./build-toolchain.sh --provision
```

`--provision` installs missing host packages with `sudo` (clang, cmake,
ninja, meson, and the rest of `PACKAGES` in the script) and rustup, before
anything is built; leave it out once the host is set up.

Every run builds everything from nothing. It fetches the heads of the branches
that `versions.sh` names (shallow clones of the Rust fork with the submodules
bootstrap needs, of mlibc, and of motor-os-tar) into `build/`, builds there,
writes the two archives and a checksum file for each next to the checkout,
and removes `build/`:

```text
../motor-toolchain-x86_64-unknown-motor-1.99.1-x86_64-linux.tar.zst
../motor-toolchain-x86_64-unknown-motor-1.99.1-x86_64-linux.tar.zst.sha256
../motor-toolchain-x86_64-unknown-motor-1.99.1.tar.zst
../motor-toolchain-x86_64-unknown-motor-1.99.1.tar.zst.sha256
```

A build replaces earlier archives of the same name there. With this checkout
beside a Motor OS checkout, the native archive is where the Motor OS build
looks for it.

A failed build leaves `build/` for inspection, and the next run deletes it
and starts over. The build uses the network for the sources, Rust's Stage 0
compiler, and the crates the build locks; Rust bootstrap runs Cargo with
`--locked`, so a lockfile that does not match its manifests fails the build.
On 24 cores a build takes about 50 minutes and needs about 30 GB of disk
while it runs. Only one build may run in a checkout at a time.

## The archives

Each archive holds one directory named like it, the way Rust's tarballs do.
motor-os-tar's `tar` writes them; GNU tar reads them too.

| Archive | Contents | Used by |
|---|---|---|
| `motor-toolchain-<name>-x86_64-linux.tar.zst` | `install.sh` and `toolchain/`, the Linux-host toolchain | Linux cross builds: the Motor OS repository, programs built beside it, third parties |
| `motor-toolchain-<name>.tar.zst` | `install.sh`, `manifest`, and `images/`, the native overlays | the Motor OS imager on Linux, and a user of a running Motor OS VM |

The host installer requires rustup on `PATH` before it copies the toolchain.
If rustup is not installed yet, install it without selecting a default:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
  sh -s -- -y --default-toolchain none
. "$HOME/.cargo/env"
```

Then install the host toolchain:

```sh
tar -xaf motor-toolchain-x86_64-unknown-motor-1.99.1-x86_64-linux.tar.zst
motor-toolchain-x86_64-unknown-motor-1.99.1-x86_64-linux/install.sh
```

`install.sh` copies the toolchain to
`~/.local/share/motor/toolchains/<name>`, or the directory given with
`--prefix DIR`, replacing an earlier installation there, and runs
`rustup toolchain link <name> <directory>`. The unpacked archive can be
deleted afterwards. A `rust-toolchain.toml` with
`channel = "x86_64-unknown-motor-1.99.1"` then selects it.

On a Motor OS VM, `install.sh` in the native archive installs the native
toolchain into `/devtools`, which the Interactive role owns:

```sh
mkdir /user/toolchain
cd /user/toolchain
tar -x -f motor-toolchain-x86_64-unknown-motor-1.99.1.tar.zst
motor-toolchain-x86_64-unknown-motor-1.99.1/install.sh
```

It replaces `/devtools/llvm` and `/devtools/rust`, copies the launchers in
`/devtools/bin`, the examples in `/devtools/src/hello-world`, and the
manifest to `/devtools/toolchain/manifest`, and refuses to replace a
different toolchain unless given `--replace`. The copies keep the modes the
unpacking session gave the files, which no lower role may execute, so it then
makes the programs executable by every role, and the launchers editable by
Interactive as well, as they are on the image. mlibc's configuration stays in
the image's `/system/cfg/libc`.

## The host toolchain

The host toolchain is a rustup toolchain directory, laid out the way Rust
lays out its own:

```text
x86_64-unknown-motor-1.99.1/
  manifest                                      the toolchain's name
  bin/                                          rustc, rustdoc, cargo, cargo-clippy,
                                                clippy-driver, rustfmt, cargo-fmt,
                                                rust-analyzer
  libexec/rust-analyzer-proc-macro-srv
  etc/, share/                                  Cargo's shell completions, manual pages
  lib/rustlib/x86_64-unknown-linux-gnu/lib/     host std
  lib/rustlib/x86_64-unknown-linux-gnu/bin/     rust-lld, rust-objcopy, clang, ld.lld,
                                                llvm-ar, llvm-ranlib, llvm-nm,
                                                llvm-objcopy, llvm-strip, llvm-readelf
  lib/rustlib/x86_64-unknown-linux-gnu/lib/clang/23/   clang's resource directory
  lib/rustlib/x86_64-unknown-motor/lib/         Motor std
  lib/rustlib/x86_64-unknown-motor/sysroot/     the cross sysroot: bin/{motor-clang,
                                                motor-clang++, motor-rust-cc} and
                                                devtools/llvm/{include,lib}
  lib/rustlib/src/rust/library/                 rust-src
```

It contains no symlinks: the LLVM tools are real files, and `ld.lld`, which
clang's Motor driver runs, is a small script that runs `rust-lld` as a GNU
linker. The wrappers find clang, its resource directory, and the sysroot
from their own location, so the directory works wherever it is installed.
Every path follows from the sysroot rustc reports:

```sh
$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-motor/sysroot/bin/motor-clang
$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-ar
```

`motor-clang` and `motor-clang++` compile and link C and C++ for Motor OS;
clang's Motor driver adds `crt1.o`, mlibc, and the C++ runtime. Cargo builds
that contain C or C++ point `CARGO_TARGET_X86_64_UNKNOWN_MOTOR_LINKER`,
`CC_x86_64_unknown_motor`, and `CXX_x86_64_unknown_motor` at them, as the
Motor OS build does. `motor-rust-cc` is the linker Rust bootstrap uses for
Motor; it names the C runtime libraries itself.

## The native overlays

`images/` in the native archive holds the toolchain's part of a Motor OS
image:

| Overlay | Contents |
|---|---|
| `llvm` | `/devtools/llvm/bin/llvm` (Clang, LLD, and the LLVM tools in one binary), its configuration and resource headers, mlibc's and libc++'s headers, the static libraries, `crt1.o`, the `cc` and `c++` launchers, and C and C++ examples |
| `rustc` | `/devtools/rust/bin/{rustc,rustfmt,clippy-driver}`, their launchers in `/devtools/bin`, the Motor standard library, and a Rust example |
| `rust-analyzer` | `/devtools/rust/bin/rust-analyzer` and the `rust-src` it indexes |
| `libc` | mlibc's runtime configuration in `/system/cfg/libc` |

Each overlay carries the toolchain's manifest as `/devtools/toolchain/manifest`.

## The manifest

`manifest` is one line, `toolchain=<name>`, which the Motor OS build and the
native `install.sh` read. It records nothing else.

## Changing the toolchain

A build takes the heads of the branches that `versions.sh` names:

1. Push the fork branches: LLVM first when its patches changed, then Rust
   with the updated gitlink, and mlibc.
2. Name the branches: `MOTOR_RUST_BRANCH` (whose head selects LLVM, Cargo, and
   the other submodules through its gitlinks), `MOTOR_MLIBC_BRANCH`, and
   `MOTOR_TAR_BRANCH`.
3. Name the release: a new Rust version restarts `MOTOR_TOOLCHAIN_RELEASE` at
   1, and any change under an already published name increments it. The
   Rust version and the beta suffix come from the fork's `src/version` and
   `src/ci/channel`.
4. Run `./build-toolchain.sh`, and run the Motor OS gates with the result.
5. Commit `versions.sh`.

A repository in `versions.sh` may be a local path, so unpublished work builds
the same way: commit it to a branch of a local checkout of the fork, point
the repository and the branch at it, and build with `--dev`, which names the
result `<name>-dev`. For LLVM, the Rust branch's `src/llvm-project` gitlink
names the commit and `MOTOR_LLVM_REPOSITORY` the repository it is fetched
from. Local builds are
packaged like releases and can be installed and used by the Motor OS build
the same way; they are not published.

## The Motor runtime crates

Three Motor OS crates enter the toolchain: `moto-rt` (linked by Rust std and,
through the `ctrlc` fork, by the compiler tools built for Motor), `moto-sys`
(used by the shim), and `moto-rt-cabi` (the shim itself). The first two come
from crates.io and the third from the mlibc fork; no path, Git source, or
`[patch]` points at a Motor OS checkout. Every reference:

| Repository | File | Reference |
|---|---|---|
| `moturus/rust` | `library/std/Cargo.toml` | `[target.'cfg(target_os = "motor")'.dependencies]` `moto-rt = { version = "0.17.9", features = ['rustc-dep-of-std'], public = true }` |
| `moturus/rust` | `library/Cargo.toml`, `[patch.crates-io]` | no Motor entry; this is where a local `moto-rt` goes for std |
| `moturus/rust` | `library/Cargo.lock` | `moto-rt 0.17.9` from the registry, a dependency of `std` |
| `moturus/rust` | `Cargo.toml` (root), `[patch.crates-io]` | `ctrlc = { git = "https://github.com/moturus/rust-ctrlc.git", branch = "motor-os-rustc" }`, plus the `libc`, `libloading`, and `stacker` forks, which do not use the runtime crates |
| `moturus/rust-ctrlc` | `Cargo.toml` | `[target.'cfg(target_os = "motor")'.dependencies]` `moto-rt = "0.17"` |
| `moturus/rust` | `Cargo.lock` (root) | `moto-rt 0.17.9` from the registry, a dependency of `ctrlc` |
| `moturus/mlibc` | `sysdeps/motor/moto-rt-cabi/Cargo.toml` | `moto-rt = { version = "0.17.9", features = ["libc"] }`, `moto-sys = "0.3.2"` |
| `moturus/mlibc` | `sysdeps/motor/moto-rt-cabi/Cargo.lock` | both from the registry; the build runs `cargo fetch --locked`, then builds `--locked --offline` |
| `moturus/mlibc` | `sysdeps/motor/moto-rt-cabi/moto_rt.h` | `#define MOTO_RT_VERSION 17u`; the crate's `build.rs` asserts it equals `moto_rt::RT_VERSION` of the `moto-rt` actually selected |
| this repository | `versions.sh` | `MOTOR_MLIBC_BRANCH` selects the shim source; only shim changes committed to that branch are built |

No build script compares these versions with the `moto-rt` in a Motor OS
checkout. The toolchain builds std against the `moto-rt` its lockfile
references from crates.io, and the Motor OS build uses the toolchain to build
whatever is in its repository; `rt.vdso` checks compatibility at runtime.

The supported way to change the runtime is to publish `moto-rt` (and
`moto-sys` if it changed), select the new versions in the manifests above,
refresh the lockfiles, and push the fork branches. Building against a Motor
OS checkout's `src/sys/lib/moto-rt` and `moto-sys` before publishing is a
local build, with `MOTOR=/absolute/path/to/motor-os`:

1. Rust fork, `library/Cargo.toml`, under `[patch.crates-io]`:
   `moto-rt = { path = "$MOTOR/src/sys/lib/moto-rt" }`. If the local version
   is outside `0.17.9`'s requirement, also bump the version in
   `library/std/Cargo.toml`, or Cargo reports the patch as unused.
2. Rust fork, root `Cargo.toml`: the same line under its `[patch.crates-io]`,
   for `ctrlc`'s `moto-rt` (`"0.17"`; bump the fork if the local major
   version changed).
3. Rust fork: refresh both lockfiles with `cargo update -p moto-rt
   --manifest-path library/Cargo.toml` and `cargo update -p moto-rt`, since
   the build refuses to change them, and commit.
4. mlibc fork, `sysdeps/motor/moto-rt-cabi/Cargo.toml`: add
   `[patch.crates-io]` with `moto-rt = { path = "$MOTOR/src/sys/lib/moto-rt" }`
   and `moto-sys = { path = "$MOTOR/src/sys/lib/moto-sys" }` (bumping the two
   version requirements if needed), run `cargo update -p moto-rt -p moto-sys`
   in that directory, and commit. Keep `MOTO_RT_VERSION` in `moto_rt.h` equal
   to the local `moto_rt::RT_VERSION`, or the shim fails to compile.
5. Point `MOTOR_RUST_REPOSITORY`, `MOTOR_RUST_BRANCH`,
   `MOTOR_MLIBC_REPOSITORY`, and `MOTOR_MLIBC_BRANCH` at the local checkouts
   and their branches, and build with `--dev`.
