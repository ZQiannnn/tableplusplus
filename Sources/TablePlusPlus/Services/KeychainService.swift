import Foundation
import Security

enum KeychainService {
    private static let service = "dev.tableplusplus.app"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func savePassword(_ password: String, for connectionID: UUID) -> OSStatus {
        guard !password.isEmpty else { return errSecParam }
        let account = connectionID.uuidString
        guard let data = password.data(using: .utf8) else { return errSecParam }
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            print("[Keychain] savePassword failed status=\(status)")
        }
        return status
    }

    static func readPassword(for connectionID: UUID) -> String? {
        var query = baseQuery(account: connectionID.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess {
            print("[Keychain] readPassword id=\(connectionID.uuidString) status=\(status)")
            return nil
        }
        guard let data = result as? Data else {
            print("[Keychain] readPassword id=\(connectionID.uuidString) success but no data")
            return nil
        }
        let pwd = String(data: data, encoding: .utf8)
        if pwd == nil || pwd!.isEmpty {
            print("[Keychain] readPassword id=\(connectionID.uuidString) decoded empty")
        }
        return pwd
    }

    static func deletePassword(for connectionID: UUID) {
        SecItemDelete(baseQuery(account: connectionID.uuidString) as CFDictionary)
    }
}
