import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH

class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private var hasTried = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !hasTried else {
            nextChallengePromise.succeed(nil)
            return
        }
        hasTried = true

        if availableMethods.contains(.password) {
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
            nextChallengePromise.succeed(offer)
        } else if availableMethods.contains(.publicKey) {
            nextChallengePromise.succeed(nil)
        } else {
            nextChallengePromise.fail(SSHTunnelError.authMethodNotSupported)
        }
    }
}

class KeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let keyPath: String?
    private var hasTried = false

    init(username: String, keyPath: String?) {
        self.username = username
        self.keyPath = keyPath
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !hasTried else {
            nextChallengePromise.succeed(nil)
            return
        }
        hasTried = true

        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHTunnelError.authMethodNotSupported)
            return
        }

        do {
            let key = try loadPrivateKey()
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: key))
            )
            nextChallengePromise.succeed(offer)
        } catch {
            nextChallengePromise.fail(error)
        }
    }

    private func loadPrivateKey() throws -> NIOSSHPrivateKey {
        if let keyPath = keyPath {
            let expandedPath = (keyPath as NSString).expandingTildeInPath
            if let key = try? loadKeyFromFile(path: expandedPath) {
                return key
            }
        }

        let defaultPaths = [
            "~/.ssh/id_ed25519",
            "~/.ssh/id_ecdsa",
            "~/.ssh/id_rsa",
        ]

        for path in defaultPaths {
            let expandedPath = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else { continue }

            if let key = try? loadKeyFromFile(path: expandedPath) {
                return key
            }
        }

        throw SSHTunnelError.noPrivateKeyFound
    }

    private func loadKeyFromFile(path: String) throws -> NIOSSHPrivateKey {
        let keyData = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw SSHTunnelError.invalidKeyFormat
        }

        if keyString.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHPrivateKey(keyString)
        }

        if keyString.contains("BEGIN") {
            return try parsePEMPrivateKey(keyString)
        }

        throw SSHTunnelError.invalidKeyFormat
    }

    private func parsePEMPrivateKey(_ pem: String) throws -> NIOSSHPrivateKey {
        if let p256Key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p256Key: p256Key)
        }
        if let p384Key = try? P384.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p384Key: p384Key)
        }
        if let p521Key = try? P521.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p521Key: p521Key)
        }
        throw SSHTunnelError.invalidKeyFormat
    }

    private func parseOpenSSHPrivateKey(_ pem: String) throws -> NIOSSHPrivateKey {
        let base64Lines =
            pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined()
        guard let binary = Data(base64Encoded: base64Lines) else {
            throw SSHTunnelError.invalidKeyFormat
        }

        var reader = OpenSSHDataReader(data: binary)
        let magic = try reader.readNullTerminatedString()
        guard magic == "openssh-key-v1" else {
            throw SSHTunnelError.invalidKeyFormat
        }

        let cipherName = try reader.readString()
        let kdfName = try reader.readString()
        _ = try reader.readData()
        let keyCount = try reader.readUInt32()

        guard cipherName == "none", kdfName == "none" else {
            throw SSHTunnelError.connectionFailed("Encrypted OpenSSH private keys are not supported yet")
        }
        guard keyCount == 1 else {
            throw SSHTunnelError.invalidKeyFormat
        }

        _ = try reader.readData()
        let privateBlob = try reader.readData()
        var privateReader = OpenSSHDataReader(data: privateBlob)

        let check1 = try privateReader.readUInt32()
        let check2 = try privateReader.readUInt32()
        guard check1 == check2 else {
            throw SSHTunnelError.connectionFailed("OpenSSH private key checkints do not match")
        }

        let keyType = try privateReader.readString()
        switch keyType {
        case "ssh-ed25519":
            _ = try privateReader.readData()
            let privateAndPublic = try privateReader.readData()
            guard privateAndPublic.count >= 64 else {
                throw SSHTunnelError.invalidKeyFormat
            }
            let privateKeyBytes = privateAndPublic.prefix(32)
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyBytes)
            _ = try privateReader.readString()
            return NIOSSHPrivateKey(ed25519Key: privateKey)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curveName = try privateReader.readString()
            _ = try privateReader.readData()
            let privateScalar = try privateReader.readMPIntData()
            _ = try privateReader.readString()
            return try makeECDSAPrivateKey(curveName: curveName, privateScalar: privateScalar)
        case "ssh-rsa":
            throw SSHTunnelError.keyTypeNotSupported("RSA")
        default:
            throw SSHTunnelError.keyTypeNotSupported(keyType)
        }
    }

    private func makeECDSAPrivateKey(curveName: String, privateScalar: Data) throws -> NIOSSHPrivateKey {
        switch curveName {
        case "nistp256":
            let key = try P256.Signing.PrivateKey(rawRepresentation: normalizeScalar(privateScalar, targetLength: 32))
            return NIOSSHPrivateKey(p256Key: key)
        case "nistp384":
            let key = try P384.Signing.PrivateKey(rawRepresentation: normalizeScalar(privateScalar, targetLength: 48))
            return NIOSSHPrivateKey(p384Key: key)
        case "nistp521":
            let key = try P521.Signing.PrivateKey(rawRepresentation: normalizeScalar(privateScalar, targetLength: 66))
            return NIOSSHPrivateKey(p521Key: key)
        default:
            throw SSHTunnelError.keyTypeNotSupported("ECDSA \(curveName)")
        }
    }

    private func normalizeScalar(_ scalar: Data, targetLength: Int) -> Data {
        let trimmedScalar = scalar.drop { $0 == 0 }
        if trimmedScalar.count >= targetLength {
            return Data(trimmedScalar.suffix(targetLength))
        }
        return Data(repeating: 0, count: targetLength - trimmedScalar.count) + trimmedScalar
    }
}

struct OpenSSHDataReader {
    private let data: Data
    private var offset: Int = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw SSHTunnelError.invalidKeyFormat
        }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { partialResult, byte in
            (partialResult << 8) | UInt32(byte)
        }
        offset += 4
        return value
    }

    mutating func readData() throws -> Data {
        let length = Int(try readUInt32())
        guard offset + length <= data.count else {
            throw SSHTunnelError.invalidKeyFormat
        }
        let value = data[offset..<(offset + length)]
        offset += length
        return Data(value)
    }

    mutating func readString() throws -> String {
        let value = try readData()
        guard let string = String(data: value, encoding: .utf8) else {
            throw SSHTunnelError.invalidKeyFormat
        }
        return string
    }

    mutating func readNullTerminatedString() throws -> String {
        guard let endIndex = data[offset...].firstIndex(of: 0) else {
            throw SSHTunnelError.invalidKeyFormat
        }
        let value = data[offset..<endIndex]
        offset = endIndex + 1
        guard let string = String(data: value, encoding: .utf8) else {
            throw SSHTunnelError.invalidKeyFormat
        }
        return string
    }

    mutating func readMPIntData() throws -> Data {
        let value = try readData()
        if value.first == 0 {
            return Data(value.dropFirst())
        }
        return value
    }
}
