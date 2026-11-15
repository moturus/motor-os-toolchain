# Dependency patches

## Rust compiler

`rust-jobserver.patch` pins Rust's manifest and lockfile to
[`moturus/jobserver-rs`](https://github.com/moturus/jobserver-rs/commit/bae15a7637b8d1660b96a4084342c1ae0a8b01de)
commit `bae15a7637b8d1660b96a4084342c1ae0a8b01de`, from `wasm-jobserver-fix`.
The fallback backend used on Motor must cancel a pending token acquisition when
its helper shuts down; otherwise native rustc can deadlock during codegen cleanup.
The build applies the dependency override to the fresh Rust checkout before
bootstrap, and Cargo fetches the pinned Git revision. The compiler and Clippy
use this source; no local jobserver checkout is required. Remove the override
when Rust selects an upstream release containing the fix.

## Native rust-analyzer

The native analyzer builds against the installed standard library. Its
remaining source rewrites are limited to the published dependencies below.
Use the published crates.io archive, not a Git checkout. Preserve its licenses.
The build downloads the archive from crates.io, verifies its
checksum (declared in `crates.sh`), and applies the patch to a fresh source
copy under `build/patched-crates/`. The host and native
rust-analyzer builds both use that copy.

| Crate | Version | Published archive SHA-256 | Patch |
|---|---|---|---|
| url | 2.5.8 | `ff67a8a4397373c3ef660812acab3268222035010ab8680ec4215f38ba3d0eed` | `url-2.5.8-motor.patch` |
| inventory | 0.3.24 | `a4f0c30c76f2f4ccee3fe55a2435f691ca00c0e4bd87abe4f4a851b1d4dac39b` | `inventory-0.3.24-motor.patch` |

The URL patch drops benchmark and wasm-only test dependencies. The crates'
own unit tests are not run by the build; Motor OS's installed-tool tests
exercise them through the native rust-analyzer on a standard-image copy.
