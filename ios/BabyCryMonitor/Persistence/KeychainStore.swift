import Foundation
import Security

struct DeviceCredential: Codable, Sendable {
    let deviceId: UUID
    let secret: String
    let role: DeviceRole
    var registered: Bool
}
protocol CredentialStoring {
    func load(role: DeviceRole, environment: String) throws -> DeviceCredential?
    func save(_ credential: DeviceCredential, environment: String) throws
    func create(role: DeviceRole) throws -> DeviceCredential
}
struct KeychainStore: CredentialStoring {
    func load(role: DeviceRole, environment: String) throws -> DeviceCredential? {
        var query = base(role: role, environment: environment)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(DeviceCredential.self, from: data)
    }
    func save(_ credential: DeviceCredential, environment: String) throws {
        let data = try JSONEncoder().encode(credential)
        let query = base(role: credential.role, environment: environment)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(entry as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else if update != errSecSuccess { throw KeychainError(status: update) }
    }
    func create(role: DeviceRole) throws -> DeviceCredential {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw KeychainError(status: result) }
        return DeviceCredential(deviceId: UUID(), secret: Data(bytes).base64EncodedString(), role: role, registered: false)
    }
    private func base(role: DeviceRole, environment: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "BabyCryMonitor.devices", kSecAttrAccount as String: "\(environment)|\(role.rawValue)"]
    }
}
struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        if status == errSecMissingEntitlement { return "Device credentials unavailable: this build is missing a Keychain signing entitlement. Use a signed build." }
        if status == errSecInteractionNotAllowed { return "Unlock this iPhone to access device credentials, then try again." }
        return "Could not access device credentials (\(status)). Check signing and Keychain availability."
    }
}
