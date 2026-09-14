import Foundation
import Security
import UIKit

/// Who is signed in, as the server describes them.
struct AuthUser: Codable, Hashable, Sendable {
    var id: String
    var email: String
    var name: String?
    var avatarUrl: String?
    var givenName: String?
    var color: String?
    var findableByEmail: Bool = false
    var membership: Membership = .guest
}

/// The session, in the Keychain: tokens, the profile, and the checked plan token.
/// Observed by the UI; everything else is static-ish through `shared`.
@MainActor
final class AuthStore: ObservableObject {
    static let shared = AuthStore()

    @Published private(set) var user: AuthUser?
    @Published private(set) var checkedToken: CheckedToken?

    /// A stable id for this phone; the plan token binds to it.
    let deviceId: String = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"

    private init() {
        user = Keychain.read(AuthUser.self, "user")
        checkedToken = Keychain.read(CheckedToken.self, "checkedToken")
    }

    var isSignedIn: Bool { Keychain.readString("refreshToken") != nil }
    var accessToken: String? { Keychain.readString("accessToken") }
    var refreshToken: String? { Keychain.readString("refreshToken") }

    func save(accessToken: String, refreshToken: String, user: AuthUser) {
        Keychain.write(accessToken, "accessToken")
        Keychain.write(refreshToken, "refreshToken")
        Keychain.write(user, "user")
        self.user = user
    }

    func updateProfile(_ changes: (inout AuthUser) -> Void) {
        guard var u = user else { return }
        changes(&u)
        Keychain.write(u, "user")
        user = u
    }

    func saveMembership(_ m: Membership) {
        updateProfile { $0.membership = m }
    }

    func saveCheckedToken(_ t: CheckedToken?) {
        if let t { Keychain.write(t, "checkedToken") } else { Keychain.delete("checkedToken") }
        checkedToken = t
    }

    /// Signs out; the checked token stays, so signing back in needs no re-entry.
    func clear() {
        for k in ["accessToken", "refreshToken", "user"] { Keychain.delete(k) }
        user = nil
    }
}

/// Tiny Keychain wrapper: one generic-password item per key, this app only.
enum Keychain {
    private static let service = "com.airadar.app"

    static func write(_ string: String, _ key: String) { write(Data(string.utf8), key) }

    static func write<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { write(data, key) }
    }

    static func write(_ data: Data, _ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func readData(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: key,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func readString(_ key: String) -> String? { readData(key).flatMap { String(data: $0, encoding: .utf8) } }

    static func read<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        readData(key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}
