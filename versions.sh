#!/usr/bin/env bash
# The recipe of the Motor toolchain release that build-toolchain.sh builds:
# its sources and build configuration. Data only.
#
# The sources are the heads of the branches named here. The release is named
# after the Rust version on MOTOR_RUST_BRANCH (its src/version):
# x86_64-unknown-motor-1.99.1. A fork of a Rust beta adds -beta, and the
# second and later releases of one Rust version add their number, as in
# x86_64-unknown-motor-1.99.1-2. A published release never changes.
#
# A repository may also be a local path; see "Changing the toolchain" in
# README.md.

MOTOR_TOOLCHAIN_RELEASE="1"

# The Rust fork. Its gitlinks select LLVM, Cargo, and the other submodules.
MOTOR_RUST_REPOSITORY="https://github.com/moturus/rust.git"
MOTOR_RUST_BRANCH="motor-os-1.99.1"
# Where the commit that the fork's src/llvm-project names is fetched from.
MOTOR_LLVM_REPOSITORY="https://github.com/moturus/llvm-project.git"
# Rust bootstrap's channel: the compilers report version 1.99.1-dev.
MOTOR_RUST_CHANNEL="dev"

MOTOR_MLIBC_REPOSITORY="https://github.com/moturus/mlibc.git"
MOTOR_MLIBC_BRANCH="motor-os-rustc"

# The tar that creates the archives.
MOTOR_TAR_REPOSITORY="https://github.com/moturus/motor-os-tar.git"
MOTOR_TAR_BRANCH="master"

MOTOR_LLVM_TARGETS="X86"

MOTOR_STANDALONE_LLVM_GENERATOR="Ninja"
MOTOR_STANDALONE_LLVM_BUILD_TYPE="Release"
MOTOR_STANDALONE_LLVM_ASSERTIONS="OFF"
MOTOR_STANDALONE_LLVM_PROJECTS="clang;lld"
MOTOR_STANDALONE_LLVM_INCLUDE_TESTS="OFF"
MOTOR_STANDALONE_LLVM_C_COMPILER="clang"
MOTOR_STANDALONE_LLVM_CXX_COMPILER="clang++"
MOTOR_RUST_BOOTSTRAP_LLVM_TOOLS=(
  llvm-cov llvm-nm llvm-objcopy llvm-objdump llvm-profdata llvm-readobj
  llvm-size llvm-strip llvm-ar llvm-as llvm-dis llvm-link llc opt
)
MOTOR_STANDALONE_LLVM_NINJA_TARGETS=(
  clang lld llvm-ranlib llvm-readelf llvm-config llvm-libraries
  "${MOTOR_RUST_BOOTSTRAP_LLVM_TOOLS[@]}"
)
