// foamy-kit 0.7.0 2031c896c17cb22f18bf68cedd06b6e6db13ddeea700850d743f7de891e80797 — do not edit; change foamy-kit and run sync
//! Shared building blocks for foamy plugin helpers (`foamy-<plugin>-helper`).
//!
//! foamy-kit's `FoamyNative` component vendors this crate into a plugin as
//! `kit/rust/foamy-helper`; the plugin's crate depends on it by path:
//!
//! ```toml
//! [dependencies]
//! foamy-helper = { path = "../kit/rust/foamy-helper" }
//! ```
//!
//! Every module keeps the bounds the Python and Bash helpers had: reads are
//! capped, files are written atomically with owner and type checks, locks
//! never block unless asked to, and child processes run with a deadline and
//! an output cap. Nothing here starts an async runtime or a background thread
//! that outlives a call.
//!
//! - [`hash`]: SHA-256 in plain Rust (`sha256`, `sha256_hex`).
//! - [`io`]: bounded reads (whole streams, files, lines with a maximum length).
//! - [`json`]: JSON-lines requests and replies, and [`json::run`], the
//!   "every failure still prints JSON" entry point.
//! - [`fs`]: atomic file writes, private directories, bounded file reads.
//! - [`lock`]: `flock` locks, including under `$XDG_RUNTIME_DIR/<plugin>`.
//! - [`child`]: bounded child processes (deadline, output cap, kill on
//!   timeout, environment control, death with the parent, standard input
//!   from bytes or an open file, CPU and I/O priority), and
//!   [`child::Pipeline`], one child's output into another's input,
//!   counted.
//! - [`net`]: [`net::DeadlineStream`], socket I/O bounded by one absolute
//!   deadline (re-armed before every read and write, so a trickling peer or
//!   a TLS layer's many reads cannot outlast it).
//! - [`process`]: this process: exit on panic, `PR_SET_PDEATHSIG`,
//!   `setsid`, rlimits, umask.
//!
//! Modules with heavier dependencies are behind cargo features, so a plugin
//! compiles only what it enables:
//!
//! - `favicon`: [`favicon`], website icons from local Chromium caches
//!   (no web requests; a built-in read-only SQLite reader).
//! - `sandbox`: [`sandbox`], seccomp-BPF filters, a Landlock exec
//!   restriction for child processes and bubblewrap command lines.
//! - `tls`: [`tls`], the one crypto provider (Graviola, with a CPU check)
//!   and the system trust store for HTTPS.

pub mod child;
#[cfg(feature = "favicon")]
pub mod favicon;
pub mod fs;
pub mod hash;
pub mod io;
pub mod json;
pub mod lock;
pub mod net;
pub mod process;
#[cfg(feature = "sandbox")]
pub mod sandbox;
#[cfg(feature = "tls")]
pub mod tls;

pub use json::Failure;
