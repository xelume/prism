import Foundation

struct UsageWindow: Equatable, Decodable {
    let usedPercent: Double
    let seconds: Int
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent", seconds = "limit_window_seconds", resetsAt = "reset_at"
    }

    var remainingPercent: Int { Int((100 - min(100, max(0, usedPercent))).rounded(.down)) }
}

struct AccountUsage: Equatable {
    let fiveHour: UsageWindow?
    let week: UsageWindow?
    let month: UsageWindow?

    init(fiveHour: UsageWindow?, week: UsageWindow?, month: UsageWindow? = nil) {
        self.fiveHour = fiveHour
        self.week = week
        self.month = month
    }

    // Match the actual duration, not primary/secondary position. Other/model-specific
    // buckets must never be presented as the account's general usage limits.
    static func decode(_ data: Data) throws -> AccountUsage {
        struct Limits: Decodable {
            let primary_window: UsageWindow?
            let secondary_window: UsageWindow?
        }
        struct Response: Decodable { let rate_limit: Limits? }
        guard data.count <= 1_048_576,
              let response = try? JSONDecoder().decode(Response.self, from: data),
              let limits = response.rate_limit else { throw UsageFailure.unsupported }
        let windows = [limits.primary_window, limits.secondary_window].compactMap { $0 }
        guard windows.allSatisfy({ $0.seconds > 0 && $0.usedPercent.isFinite && $0.usedPercent >= 0 &&
            ($0.resetsAt == nil || ($0.resetsAt!.isFinite && $0.resetsAt! > 0 && $0.resetsAt! < 253_402_300_800)) }) else {
            throw UsageFailure.unsupported
        }
        let five = windows.filter { $0.seconds == 18_000 }
        let week = windows.filter { $0.seconds == 604_800 }
        let month = windows.filter { (28 * 86_400...31 * 86_400).contains($0.seconds) }
        guard five.count <= 1, week.count <= 1, month.count <= 1 else {
            throw UsageFailure.unsupported
        }
        return AccountUsage(fiveHour: five.first, week: week.first, month: month.first)
    }
}

enum UsageFailure: Error, Equatable {
    case expired, forbidden, throttled(TimeInterval), unavailable, unsupported

    var message: String {
        switch self {
        case .expired: return L10n.text("usage.failure.signInAgain")
        case .forbidden: return L10n.text("usage.failure.unavailable")
        case .throttled: return L10n.text("usage.failure.tryLater")
        case .unavailable: return L10n.text("usage.failure.unavailable")
        case .unsupported: return L10n.text("usage.failure.noInformation")
        }
    }

    var retryDelay: TimeInterval {
        if case .throttled(let delay) = self { return max(300, min(3600, delay)) }
        return 300
    }
}

// No cookies, shared credential store, redirects, token refresh, or auth-file writes.
// The endpoint is observed in the checked desktop version, not a public stable API.
final class UsageClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func request(for auth: AuthSnapshot) throws -> URLRequest {
        let values = [auth.accessToken, auth.accountID]
        guard values.allSatisfy({ value in
            !value.isEmpty && value.utf8.count < 32_768 &&
            value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
        }) else { throw UsageFailure.unsupported }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer " + auth.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Prism", forHTTPHeaderField: "originator")
        return request
    }

    static func validate(_ response: HTTPURLResponse, now: Date = Date()) throws {
        guard response.url == endpoint else { throw UsageFailure.unavailable }
        switch response.statusCode {
        case 200: return
        case 401: throw UsageFailure.expired
        case 403: throw UsageFailure.forbidden
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let delay = Double(header) ?? formatter.date(from: header)?.timeIntervalSince(now) ?? 300
            throw UsageFailure.throttled(delay.isFinite ? max(300, min(3600, delay)) : 300)
        case 404: throw UsageFailure.unsupported
        default: throw UsageFailure.unavailable
        }
    }

    func fetch(_ auth: AuthSnapshot) async throws -> AccountUsage {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: Self.request(for: auth))
            guard let response = response as? HTTPURLResponse else { throw UsageFailure.unavailable }
            try Self.validate(response)
            guard response.expectedContentLength <= 1_048_576 else { throw UsageFailure.unsupported }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { throw UsageFailure.unsupported }
                data.append(byte)
            }
            return try AccountUsage.decode(data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as UsageFailure { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw UsageFailure.unavailable
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
