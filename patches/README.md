# Patched crates for native rust-analyzer

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
own unit tests are not run by the build; Motor OS's developer-image suite
exercises them through the native rust-analyzer.
