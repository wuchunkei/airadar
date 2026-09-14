import Foundation
import GoogleSignIn
import UIKit

/// Google's own account sheet, through the GoogleSignIn SDK. The ID token is
/// minted for the Web client (GIDServerClientID), which is what the backend
/// verifies — the same token the Android app sends.
enum GoogleAuth {

    struct Cancelled: Error {}

    @MainActor
    private static func presenter() throws -> UIViewController {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else {
            throw BackendClient.BackendError(message: "No window to present sign-in.", code: 0)
        }
        var top = root
        while let next = top.presentedViewController { top = next }
        return top
    }

    @MainActor
    static func configure() {
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: Config.googleClientId,
            serverClientID: Config.googleServerClientId.isEmpty ? nil : Config.googleServerClientId
        )
    }

    /// Shows the picker and returns the ID token.
    @MainActor
    static func idToken() async throws -> String {
        guard !Config.googleClientId.isEmpty else {
            throw BackendClient.BackendError(message: "Google sign-in is not configured — set GID_CLIENT_ID in Config.xcconfig.", code: 0)
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: try presenter())
            guard let token = result.user.idToken?.tokenString else {
                throw BackendClient.BackendError(message: "Google returned no ID token.", code: 0)
            }
            return token
        } catch let e as GIDSignInError where e.code == .canceled {
            throw Cancelled()
        }
    }

    /// Adds Gmail read access to the signed-in Google account and returns an access token for it.
    @MainActor
    static func gmailAccessToken() async throws -> String {
        let scope = "https://www.googleapis.com/auth/gmail.readonly"
        var user = GIDSignIn.sharedInstance.currentUser
        if user == nil { user = try await GIDSignIn.sharedInstance.restorePreviousSignIn() }
        guard let current = user else {
            throw BackendClient.BackendError(message: "Sign in with Google first.", code: 0)
        }
        if !(current.grantedScopes ?? []).contains(scope) {
            let result = try await current.addScopes([scope], presenting: try presenter())
            return result.user.accessToken.tokenString
        }
        return current.accessToken.tokenString
    }
}
