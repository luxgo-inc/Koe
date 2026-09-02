import AuthenticationServices
import CryptoKit
import Foundation
import KoeKit
import Observation
import UIKit

/// Google OAuth（PKCE 付き認可コードフロー）の手実装。外部SDK依存なし。
/// iOS クライアント ID はシークレット不要。scope は drive.file（自アプリ作成分のみ）。
/// トークンは KeychainStore（jp.luxgo.koe サービス）に保存する。
@MainActor
@Observable
final class GoogleOAuthClient: NSObject {
    static let shared = GoogleOAuthClient()

    private static let refreshAccount = "google-refresh-token"
    private static let accessAccount = "google-access-token"
    private static let expiryKey = "googleAccessTokenExpiry"

    private(set) var isSignedIn: Bool

    override private init() {
        isSignedIn = KeychainStore.load(account: Self.refreshAccount) != nil
        super.init()
    }

    enum OAuthError: LocalizedError {
        case clientIDMissing
        case badCallback
        case tokenExchangeFailed(String)
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .clientIDMissing:
                return "Google クライアントIDが未設定です。ios/Config.xcconfig に GOOGLE_OAUTH_CLIENT_ID を設定して再ビルドしてください。"
            case .badCallback:
                return "サインインがキャンセルされたか、応答を解釈できませんでした。"
            case .tokenExchangeFailed(let detail):
                return "トークン取得に失敗しました: \(detail)"
            case .notSignedIn:
                return "Google にサインインしていません。"
            }
        }
    }

    private var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String) ?? ""
    }

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc"
    private var redirectScheme: String? {
        let parts = clientID.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        return parts.reversed().joined(separator: ".")
    }

    func signIn() async throws {
        guard !clientID.isEmpty, let scheme = redirectScheme else {
            throw OAuthError.clientIDMissing
        }
        let verifier = Self.randomURLSafeString(count: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let redirectURI = "\(scheme):/oauth2redirect"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let authURL = comps.url!

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? OAuthError.badCallback)
                }
            }
            session.presentationContextProvider = self
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.badCallback
        }
        let tokens = try await Self.tokenRequest(params: [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        storeTokens(tokens)
        isSignedIn = true
    }

    func signOut() {
        KeychainStore.delete(account: Self.refreshAccount)
        KeychainStore.delete(account: Self.accessAccount)
        UserDefaults.standard.removeObject(forKey: Self.expiryKey)
        isSignedIn = false
    }

    /// 有効な access token を返す。期限切れなら refresh token で更新する。
    func accessToken() async throws -> String {
        let expiry = UserDefaults.standard.double(forKey: Self.expiryKey)
        if let token = KeychainStore.load(account: Self.accessAccount),
           Date().timeIntervalSince1970 < expiry - 60 {
            return token
        }
        guard let refreshToken = KeychainStore.load(account: Self.refreshAccount) else {
            throw OAuthError.notSignedIn
        }
        do {
            let tokens = try await Self.tokenRequest(params: [
                "refresh_token": refreshToken,
                "client_id": clientID,
                "grant_type": "refresh_token",
            ])
            storeTokens(tokens)
            return tokens.accessToken
        } catch let error as OAuthError {
            if case .tokenExchangeFailed(let detail) = error, detail.contains("invalid_grant") {
                // refresh token 失効（アカウント側で取り消し等）→ 再サインインが必要
                signOut()
                throw OAuthError.notSignedIn
            }
            throw error
        }
    }

    private struct TokenResponse {
        let accessToken: String
        let expiresIn: TimeInterval
        let refreshToken: String?
    }

    private func storeTokens(_ tokens: TokenResponse) {
        KeychainStore.save(tokens.accessToken, account: Self.accessAccount)
        UserDefaults.standard.set(
            Date().timeIntervalSince1970 + tokens.expiresIn, forKey: Self.expiryKey)
        if let refresh = tokens.refreshToken {
            KeychainStore.save(refresh, account: Self.refreshAccount)
        }
    }

    private static func tokenRequest(params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? TimeInterval else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw OAuthError.tokenExchangeFailed(body)
        }
        return TokenResponse(
            accessToken: accessToken,
            expiresIn: expiresIn,
            refreshToken: json["refresh_token"] as? String)
    }

    private static func randomURLSafeString(count: Int) -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<count).map { _ in charset.randomElement()! })
    }
}

extension GoogleOAuthClient: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
