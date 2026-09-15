import Foundation

struct TLSConfig: Codable, Hashable {
    var enabled: Bool = false
    var verifyServerCertificate: Bool = true
    var caCertificatePath: String = ""
    var clientCertificatePath: String = ""
    var clientKeyPath: String = ""
}
