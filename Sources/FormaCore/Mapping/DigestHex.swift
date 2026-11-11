import CryptoKit
import Foundation

extension Digest {
    /// Lowercase hexadecimal, the form every artifact digest and fingerprint in
    /// Forma is written and compared in.
    var hexadecimalDigest: String { map { String(format: "%02x", $0) }.joined() }
}
