import Foundation
import Security

struct Credentials {
    let email: String
    let apiToken: String

    var displayAccount: String { email }
}

enum KeychainError: Error {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
    case dataConversionError
    case attributeError
}

class KeychainService {
    static let shared = KeychainService()
    private let service = Bundle.main.bundleIdentifier ?? "com.example.BuildMonitor" // Use your app's bundle ID

    private init() {} // Singleton

    func saveCredentials(_ credentials: Credentials) throws {
        // Delete existing items first to avoid duplicates
        try? deleteCredentials()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentials.email,
            kSecValueData as String: credentials.apiToken.data(using: .utf8)!
            // Consider adding kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        print("Keychain: Credentials saved successfully.")
    }

    func loadCredentials() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else {
            throw KeychainError.itemNotFound
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let existingItem = item as? [String: Any],
              let passwordData = existingItem[kSecValueData as String] as? Data,
              let email = existingItem[kSecAttrAccount as String] as? String,
              let apiToken = String(data: passwordData, encoding: .utf8)
        else {
            throw KeychainError.dataConversionError
        }

        print("Keychain: Credentials loaded successfully.")
        return Credentials(email: email, apiToken: apiToken)
    }

    func deleteCredentials() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            print("Keychain: Error deleting credentials - Status: \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
         print("Keychain: Credentials deleted (or did not exist).")
    }
}
