// NIOSSL Swift module is unbuildable on Windows. The X.509 / NIOSSL bridging helpers in this
// file are unavailable on Windows. See bucket/HANDOFF-vapor-investigation-2026-05-14.md.
#if !os(Windows)
import X509
import NIOSSL
import SwiftASN1

extension NIOSSLCertificate {
    // Convert NIOSSL certificate to X509 certificate. Currently requires to go
    // to throught the DER representation. This only used in few cases and
    // should not impact the performance of most users.
    @inlinable
    func toX509Certificate() throws -> X509.Certificate {
        let derBytes = try self.toDERBytes()
        return try X509.Certificate(derEncoded: derBytes)
    }
}

extension NIOSSL.ValidatedCertificateChain {
    // The precondition holds because the `NIOSSL.ValidatedCertificateChain` always contains one `NIOSSLCertificate`.
    @inlinable
    func usingX509Certificates() throws -> X509.ValidatedCertificateChain {
        // This is safe because we this certificate chain is verified in NIOSSL.
        return .init(uncheckedCertificateChain: try self.map { try $0.toX509Certificate() })
    }
}

#endif // !os(Windows)
