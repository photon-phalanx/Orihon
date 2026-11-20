import CryptoKit
import Foundation

/// iOS protocol from 接口请求签名说明 / 业务接口与参数参考 (2026-11-20).
/// This client never uses website cookies, and never sends account credentials to media servers.
public actor BikaAPI {
    public static let shared = BikaAPI()
    public static let baseURL = URL(string: "https://api.tipatipa.xyz")!
    static let apiKey = "2587EFC6F859B4E3A1D8B6D33B272"
    private static let signingKey = SymmetricKey(data: Data(#"aWOuRTPH'$v#c[xh/++7g-?}#fHa28Wx*9"VUkE5Uxz'HLDhwLV#D",{k]ZL;F:"#.utf8))
    // The service rejects otherwise valid signed requests with URLSession's default UA (401/1005).
    static let userAgent = "sora/2 CFNetwork/1492.0.1 Darwin/23.3.0"
    private static let tokenKey = "bika.ios.token.v1"
    private let session: URLSession
    private let persistsToken: Bool
    private var token: String?
    private var generation = UUID()
    private var timeOffset: TimeInterval = 0
    private let deviceID: String

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: BikaNoRedirect(), delegateQueue: nil)
        persistsToken = true
        token = MihonSecretStore.data(for: Self.tokenKey).flatMap { String(data: $0, encoding: .utf8) }
        let key = "orihon.bika.deviceID"
        let id = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        deviceID = id
    }

    init(session: URLSession, token: String? = nil) {
        self.session = session
        self.token = token
        persistsToken = false
        deviceID = "Orihon-Tests"
    }

    public var isLoggedIn: Bool { token != nil }

    static func signature(path: String, method: String, time: String, nonce: String) -> String {
        let message = (nonce + method + String(path.dropFirst()) + apiKey + time).uppercased()
        return BikaWebsite.hmacSHA256(for: Data(message.utf8), using: signingKey)
    }

    /// Encode each field separately: '+' must never become a space, arrays use repeated [] keys.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
    }

    static func form(_ fields: [(String, String)]) -> Data {
        Data(fields.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&").utf8)
    }

    func request<T: Decodable & Sendable>(_ path: String, form: [(String, String)]? = nil,
                                         authenticated: Bool = true) async throws -> T {
        try Task.checkCancellation()
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("#"),
              let url = URL(string: Self.baseURL.absoluteString + path), url.host == Self.baseURL.host else {
            throw URLError(.badURL)
        }
        if authenticated && token == nil { throw BikaReadError.login }
        let current = generation
        // Sign the exact encoded URL sent on the wire, including the original query ordering.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let signedPath = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        for attempt in 0..<2 {
            let stamp = String(Int(Date().timeIntervalSince1970 + timeOffset))
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let method = form == nil ? "GET" : "POST"
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.allHTTPHeaderFields = [
                "api-key": Self.apiKey, "accept": "application/vnd.picacomic.com.v1+json",
                "app-platform": "ios", "app-version": "2.1.2.5", "app-build-version": "34",
                "app-uuid": deviceID, "User-Agent": Self.userAgent, "time": stamp, "nonce": nonce,
                "signature": Self.signature(path: signedPath, method: method, time: stamp, nonce: nonce)
            ]
            if authenticated { request.setValue(token, forHTTPHeaderField: "authorization") }
            if let form {
                request.httpBody = Self.form(form)
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw BikaReadError.unavailable }
            let envelope = try? JSONDecoder().decode(BikaResponseStatus.self, from: data)
            let unauthorized = http.statusCode == 401 || envelope?.code == 401
            if unauthorized, attempt == 0, let serverTime = http.value(forHTTPHeaderField: "server-time").flatMap(Double.init),
               abs(serverTime - Date().timeIntervalSince1970 - timeOffset) > 30 {
                timeOffset = serverTime - Date().timeIntervalSince1970
                continue
            }
            if unauthorized {
                if authenticated {
                    token = nil
                    if persistsToken { MihonSecretStore.set(nil, for: Self.tokenKey) }
                    await BikaWebsite.clearBrowseCache()
                    throw BikaReadError.login
                }
                throw BikaAPIError.authentication
            }
            guard (200..<300).contains(http.statusCode), envelope?.code == 200 else {
                throw BikaAPIError.response(envelope?.code ?? http.statusCode)
            }
            do { return try JSONDecoder().decode(BikaEnvelope<T>.self, from: data).data }
            catch { throw BikaReadError.unavailable }
        }
        throw BikaReadError.unavailable
    }

    public func login(account: String, password: String) async throws {
        generation = UUID()
        let current = generation
        struct Login: Decodable, Sendable { let token: String }
        let result: Login = try await request("/auth/sign-in", form: [("email", account.trimmingCharacters(in: .whitespacesAndNewlines)), ("password", password)], authenticated: false)
        guard !result.token.isEmpty, generation == current else { throw BikaReadError.unavailable }
        if persistsToken {
            let data = Data(result.token.utf8)
            MihonSecretStore.set(data, for: Self.tokenKey)
            guard MihonSecretStore.data(for: Self.tokenKey) == data else { throw BikaAPIError.storage }
        }
        token = result.token
        await BikaWebsite.clearBrowseCache()
    }

    public func logout() async {
        generation = UUID()
        token = nil
        if persistsToken { MihonSecretStore.set(nil, for: Self.tokenKey) }
        await BikaWebsite.clearBrowseCache()
    }

    public func profile() async throws -> BikaProfile {
        struct Profile: Decodable, Sendable { let user: BikaProfile }
        let response: Profile = try await request("/users/profile")
        return response.user
    }

    public func sources() async throws -> BikaSources { try await request("/sources") }
}

private final class BikaNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
private struct BikaResponseStatus: Decodable { let code: Int }
private struct BikaEnvelope<T: Decodable>: Decodable { let data: T }

public struct BikaProfile: Decodable, Sendable {
    public let name: String
    public let level: Int
}
public struct BikaSources: Decodable, Sendable {
    public let prodUrl: String
    public let prodChat: String
}
public enum BikaAPIError: LocalizedError {
    case authentication, response(Int), storage
    public var errorDescription: String? {
        switch self {
        case .authentication: "哔咔登录未通过，请检查账号、密码与设备时间。"
        case .response(let code): "哔咔接口暂时不可用（\(code)），请稍后重试。"
        case .storage: "无法安全保存哔咔登录状态，请检查应用签名的钥匙串权限。"
        }
    }
}
