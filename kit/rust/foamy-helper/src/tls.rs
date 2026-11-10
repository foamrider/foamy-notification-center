// foamy-kit 0.8.1 1f90a4df7260b1c57e6dd972ca68fc82191f94cc8a1e47082e4f26154c0e24aa — do not edit; change foamy-kit and run sync
//! TLS for helpers that make HTTPS requests (feature `tls`): one crypto
//! provider and one trust store for every foamy helper.
//!
//! - Cryptography is [Graviola](https://github.com/ctz/graviola) through
//!   `rustls-graviola`: Rust and assembly only, so both musl targets build
//!   with rustc alone and reproducibly (ring and aws-lc-rs compile C, which
//!   would tie the binaries' bytes to the build machine's C compiler).
//! - Graviola needs, on x86_64, AES-NI, carry-less multiplication
//!   (PCLMULQDQ), SSSE3, AVX, AVX2, BMI1, BMI2 and ADX (Intel Broadwell / AMD
//!   Zen or newer); on aarch64 the ARMv8 crypto extensions: AES, PMULL and
//!   SHA-2, with NEON (Apple Silicon, Raspberry Pi 5; **not** a Pi 4).
//!   Without them it would abort in the first handshake, so call
//!   [`cpu_supported`] (or let [`client_config`] do it) and report
//!   [`UNSUPPORTED`] instead.
//! - The trust store is the system's (`rustls-native-certs`: `SSL_CERT_FILE`
//!   / `SSL_CERT_DIR` when set, else OpenSSL's default locations), loaded once
//!   per process ([`system_roots`]).
//!
//! With ureq (`default-features = false, features = ["rustls-no-provider"]`):
//!
//! ```ignore
//! use std::sync::Arc;
//! use ureq::tls::{Certificate, RootCerts, TlsConfig, TlsProvider};
//! foamy_helper::tls::ensure_supported()?;
//! // ureq 3 has its own certificate type.
//! let roots: Vec<Certificate<'static>> = foamy_helper::tls::system_roots_der()
//!     .iter()
//!     .map(|der| Certificate::from_der(der.as_ref()).to_owned())
//!     .collect();
//! let tls = TlsConfig::builder()
//!     .provider(TlsProvider::Rustls)
//!     .root_certs(RootCerts::Specific(Arc::new(roots)))
//!     .unversioned_rustls_crypto_provider(foamy_helper::tls::provider())
//!     .build();
//! ```
//!
//! ureq's `timeout_global` bounds each read by the time left, but its CONNECT
//! proxy reply loop does not: put a deadline-capping transport in ureq's
//! connector chain (foamy-train's `native/src/net.rs` `DeadlineConnector`), or
//! use [`crate::net::DeadlineStream`] under your own HTTP code.

use std::fmt;
use std::sync::{Arc, OnceLock};

pub use rustls;
use rustls::crypto::CryptoProvider;
use rustls::pki_types::CertificateDer;
use rustls::{ClientConfig, RootCertStore};

/// The user-facing reason when [`cpu_supported`] is false. It names the
/// headline requirements; [`cpu_supported`] checks the full list (the module
/// docs). Plugins use this exact text as an i18n catalog key, so a change here
/// is a change to every plugin's catalogs.
pub const UNSUPPORTED: &str = "HTTPS isn't supported on this CPU (foamy helpers need AES, carry-less multiply, AVX2, BMI2 and ADX on x86-64, or the crypto extensions on ARMv8)";

/// Why a TLS configuration could not be built.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TlsError {
    /// This CPU lacks instructions Graviola needs (see the module docs).
    UnsupportedCpu,
    /// The system trust store had no usable certificate.
    NoRoots,
    /// rustls refused the configuration (a message for logs, no secrets).
    Config(String),
}

impl fmt::Display for TlsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TlsError::UnsupportedCpu => f.write_str(UNSUPPORTED),
            TlsError::NoRoots => f.write_str("no usable CA certificate in the system trust store"),
            TlsError::Config(message) => write!(f, "TLS configuration: {message}"),
        }
    }
}

impl std::error::Error for TlsError {}

/// True when this CPU has every instruction Graviola needs (x86_64: AES,
/// PCLMULQDQ, SSSE3, AVX, AVX2, BMI1, BMI2, ADX; aarch64: NEON, AES, PMULL,
/// SHA-2). Checked at run time, once per call (`is_*_feature_detected!` caches).
pub fn cpu_supported() -> bool {
    #[cfg(target_arch = "x86_64")]
    {
        std::arch::is_x86_feature_detected!("aes")
            && std::arch::is_x86_feature_detected!("pclmulqdq")
            && std::arch::is_x86_feature_detected!("ssse3")
            && std::arch::is_x86_feature_detected!("avx")
            && std::arch::is_x86_feature_detected!("avx2")
            && std::arch::is_x86_feature_detected!("bmi1")
            && std::arch::is_x86_feature_detected!("bmi2")
            && std::arch::is_x86_feature_detected!("adx")
    }
    #[cfg(target_arch = "aarch64")]
    {
        std::arch::is_aarch64_feature_detected!("neon")
            && std::arch::is_aarch64_feature_detected!("aes")
            && std::arch::is_aarch64_feature_detected!("pmull")
            && std::arch::is_aarch64_feature_detected!("sha2")
    }
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    {
        false
    }
}

/// `Err(TlsError::UnsupportedCpu)` when [`cpu_supported`] is false.
pub fn ensure_supported() -> Result<(), TlsError> {
    if cpu_supported() {
        Ok(())
    } else {
        Err(TlsError::UnsupportedCpu)
    }
}

/// The crypto provider every foamy helper uses (Graviola). Building it is
/// safe on any CPU; only a handshake needs the instructions.
pub fn provider() -> Arc<CryptoProvider> {
    static PROVIDER: OnceLock<Arc<CryptoProvider>> = OnceLock::new();
    Arc::clone(PROVIDER.get_or_init(|| Arc::new(rustls_graviola::default_provider())))
}

/// The system trust store as DER certificates, loaded once per process.
/// Unreadable or malformed entries are skipped (as OpenSSL does).
pub fn system_roots_der() -> Arc<Vec<CertificateDer<'static>>> {
    static ROOTS: OnceLock<Arc<Vec<CertificateDer<'static>>>> = OnceLock::new();
    Arc::clone(ROOTS.get_or_init(|| Arc::new(rustls_native_certs::load_native_certs().certs)))
}

/// The system trust store as a rustls [`RootCertStore`]; `Err(NoRoots)`
/// when no certificate in it parses.
pub fn system_roots() -> Result<Arc<RootCertStore>, TlsError> {
    let mut roots = RootCertStore::empty();
    let (added, _ignored) = roots.add_parsable_certificates(system_roots_der().iter().cloned());
    if added == 0 {
        return Err(TlsError::NoRoots);
    }
    Ok(Arc::new(roots))
}

/// A client configuration with WebPKI verification against
/// [`system_roots`]: TLS 1.2 and 1.3, no client certificate. Checks
/// [`cpu_supported`] first.
pub fn client_config() -> Result<Arc<ClientConfig>, TlsError> {
    ensure_supported()?;
    let config = ClientConfig::builder_with_provider(provider())
        .with_protocol_versions(rustls::ALL_VERSIONS)
        .map_err(|error| TlsError::Config(error.to_string()))?
        .with_root_certificates(system_roots()?)
        .with_no_client_auth();
    Ok(Arc::new(config))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_is_shared_and_complete() {
        let a = provider();
        let b = provider();
        assert!(Arc::ptr_eq(&a, &b));
        assert!(!a.cipher_suites.is_empty());
        assert!(!a.kx_groups.is_empty());
    }

    #[test]
    fn unsupported_cpu_is_reported_not_aborted() {
        match client_config() {
            Ok(_) => assert!(cpu_supported()),
            Err(TlsError::UnsupportedCpu) => assert!(!cpu_supported()),
            // A build host without a CA bundle.
            Err(TlsError::NoRoots) => assert!(cpu_supported()),
            Err(other) => panic!("unexpected {other}"),
        }
        assert_eq!(TlsError::UnsupportedCpu.to_string(), UNSUPPORTED);
    }

    #[test]
    fn unsupported_text_is_the_catalog_key() {
        // Plugins' i18n catalogs are keyed by this exact text.
        assert_eq!(
            UNSUPPORTED,
            "HTTPS isn't supported on this CPU (foamy helpers need AES, carry-less multiply, \
             AVX2, BMI2 and ADX on x86-64, or the crypto extensions on ARMv8)"
        );
    }
}
