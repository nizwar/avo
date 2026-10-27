import Foundation
import Security

/// How this process is signed.
public enum SigningIdentity {
    /// A Developer ID signature: a release, as opposed to a local build
    /// (ad hoc or Apple Development). The leaf certificate of a Developer
    /// ID app is named "Developer ID Application: …".
    public static let isDeveloperID: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else {
            return false
        }
        var common: CFString?
        guard SecCertificateCopyCommonName(leaf, &common) == errSecSuccess, let name = common as String? else { return false }
        return name.hasPrefix("Developer ID Application:")
    }()
}
