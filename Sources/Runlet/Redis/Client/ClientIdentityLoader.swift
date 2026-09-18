import Foundation
import Network
import Security

/// A client identity loaded from a certificate + private key pair, ready to be
/// handed to `sec_protocol_options_set_local_identity`.
///
/// The temporary keychain (when present) must stay alive for the entire lifetime
/// of the TLS connection: the `sec_identity_t` keeps referencing the private
/// key that lives inside it. Callers retain this struct on the client for the
/// connection's duration and delete the keychain on disconnect.
struct LoadedClientIdentity: @unchecked Sendable {
    let secIdentity: sec_identity_t
    let keychain: SecKeychain?
}

enum ClientIdentityLoaderError: LocalizedError {
    case incompleteConfiguration
    case keychainCreateFailed(OSStatus)
    case importFailed(OSStatus)
    case identityCreationFailed(OSStatus)
    case certificateUnreadable

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration:
            return "Both a client certificate and a client key file are required for TLS client authentication."
        case let .keychainCreateFailed(status):
            return "Failed to create a temporary keychain for the client certificate (status \(status))."
        case let .importFailed(status):
            return "Failed to import the client certificate or key file (status \(status))."
        case let .identityCreationFailed(status):
            return "Failed to assemble the client identity from the certificate and key (status \(status))."
        case .certificateUnreadable:
            return "The client certificate file could not be read."
        }
    }
}

/// Loads a client identity from a certificate file and a private key file.
/// Returns `nil` when neither path is configured. Throws when configuration is
/// incomplete or the identity cannot be assembled, so misconfiguration is
/// surfaced instead of silently ignored.
func loadClientIdentity(certificatePath: String, keyPath: String) throws -> LoadedClientIdentity? {
    let certPath = certificatePath.trimmingCharacters(in: .whitespacesAndNewlines)
    let keyPathTrimmed = keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !certPath.isEmpty, !keyPathTrimmed.isEmpty else {
        return nil
    }

    let certURL = URL(filePath: certPath)
    let keyURL = URL(filePath: keyPathTrimmed)

    let certIsPKCS12 = ["p12", "pfx"].contains(certURL.pathExtension.lowercased())
    let keyIsPKCS12 = ["p12", "pfx"].contains(keyURL.pathExtension.lowercased())
    if certIsPKCS12 || keyIsPKCS12 {
        return try loadPKCS12(at: certIsPKCS12 ? certURL : keyURL)
    }

    // Separate PEM cert + key: `SecIdentityCreateWithCertificate` only finds the
    // private key when it already lives in a keychain, so import both into a
    // throwaway keychain and assemble the identity from there. (`SecIdentityCreate`
    // from in-memory key material is not an option: `SecKeyCreateWithData`
    // rejects PKCS#8 and SEC1, the formats modern tools emit by default.)
    let (keychain, keychainPath) = try createTemporaryKeychain()

    do {
        _ = try importItem(at: keyURL, into: keychain, format: SecExternalFormat.formatPEMSequence)
        _ = try importItem(at: certURL, into: keychain, format: SecExternalFormat.formatPEMSequence)

        let certData: Data
        do {
            certData = try Data(contentsOf: certURL)
        } catch {
            throw ClientIdentityLoaderError.certificateUnreadable
        }
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw ClientIdentityLoaderError.certificateUnreadable
        }

        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(keychain as CFTypeRef?, cert, &identity)
        guard status == errSecSuccess, let identity else {
            throw ClientIdentityLoaderError.identityCreationFailed(status)
        }
        guard let secIdentity = sec_identity_create(identity) else {
            throw ClientIdentityLoaderError.identityCreationFailed(status)
        }
        return LoadedClientIdentity(secIdentity: secIdentity, keychain: keychain)
    } catch {
        deleteKeychainFile(at: keychainPath)
        throw error
    }
}

private func createTemporaryKeychain() throws -> (SecKeychain, String) {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("runlet-tls-\(UUID().uuidString).keychain")
    let path = fileURL.path
    try? FileManager.default.removeItem(at: fileURL)
    let password = UUID().uuidString
    var keychain: SecKeychain?
    let status = SecKeychainCreate(
        path,
        UInt32(password.utf8.count),
        password,
        false,
        nil,
        &keychain
    )
    guard status == errSecSuccess, let keychain else {
        throw ClientIdentityLoaderError.keychainCreateFailed(status)
    }
    return (keychain, path)
}

private func importItem(at url: URL, into keychain: SecKeychain, format: SecExternalFormat) throws -> CFArray? {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw ClientIdentityLoaderError.certificateUnreadable
    }
    var format = format
    var items: CFArray?
    let status = SecItemImport(
        data as CFData,
        nil,
        &format,
        nil,
        SecItemImportExportFlags(),
        nil,
        keychain,
        &items
    )
    guard status == errSecSuccess else {
        throw ClientIdentityLoaderError.importFailed(status)
    }
    return items
}

private func loadPKCS12(at url: URL) throws -> LoadedClientIdentity {
    let (keychain, keychainPath) = try createTemporaryKeychain()
    do {
        // Unencrypted PKCS#12: no passphrase, so keyParams is nil. Encrypted archives
        // fail the import and surface a clear error instead of being silently ignored.
        guard let items = try importItem(at: url, into: keychain, format: SecExternalFormat.formatPKCS12) else {
            throw ClientIdentityLoaderError.importFailed(errSecInternalComponent)
        }
        let array = items as NSArray
        guard let dict = array.firstObject as? NSDictionary else {
            throw ClientIdentityLoaderError.identityCreationFailed(errSecInternalComponent)
        }
        guard let rawIdentity = dict[kSecImportItemIdentity] else {
            throw ClientIdentityLoaderError.identityCreationFailed(errSecInternalComponent)
        }
        // CF types bridge unconditionally; the guard above already proves the
        // p12 contains an identity, so the cast is safe here.
        // swiftlint:disable:next force_cast
        let identity = rawIdentity as! SecIdentity
        guard let secIdentity = sec_identity_create(identity) else {
            throw ClientIdentityLoaderError.identityCreationFailed(errSecInternalComponent)
        }
        // The identity (cert + key) lives in the temporary keychain, so it is valid
        // for the connection lifetime and cleaned up on disconnect via `keychain`.
        return LoadedClientIdentity(secIdentity: secIdentity, keychain: keychain)
    } catch {
        deleteKeychainFile(at: keychainPath)
        throw error
    }
}

/// Removes the temporary keychain file. Called on every failure path so failed
/// TLS setups never leave files behind in the temporary directory.
private func deleteKeychainFile(at path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

/// Removes temporary keychains orphaned by a previous crash or `kill -9`.
/// Disconnect and failure paths delete their own keychain, so at launch every
/// `runlet-tls-*.keychain` file belongs to a dead process. Mirrors the
/// system-ssh socket sweep; the temporary directory is per-user, so only our
/// own files are ever visible here.
func sweepStaleTemporaryKeychains() {
    let dir = FileManager.default.temporaryDirectory
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
    for name in names where name.hasPrefix("runlet-tls-") {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}
