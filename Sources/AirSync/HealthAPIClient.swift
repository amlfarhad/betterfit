import Foundation

struct HTTPResult: Sendable {
    let data: Data
    let status: Int
    var retryAfter: String? = nil
    var responseURL: URL? = nil
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct HealthAPIClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> HTTPResult
    let accessToken: @Sendable () async throws -> String
    let transport: Transport
    let sleep: @Sendable (UInt64) async throws -> Void

    init(accessToken: @escaping @Sendable () async throws -> String,
         transport: @escaping Transport = HealthAPIClient.liveTransport(),
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.accessToken = accessToken; self.transport = transport; self.sleep = sleep
    }

    static func liveTransport() -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
        return { request in
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw SyncError.malformedResponse }
            return HTTPResult(data: data, status: response.statusCode,
                              retryAfter: response.value(forHTTPHeaderField: "Retry-After"), responseURL: response.url)
        }
    }

    func profileAge() async throws -> Double {
        let profile = try await get(path: "users/me/profile", query: [])
        guard let age = try? profile["age"].numeric(18, 120) else { throw SyncError.invalidProfileAge }
        return age
    }

    func fetch(_ metric: HealthMetric, window: QueryWindow, timeZone: TimeZone) async throws -> [JSONValue] {
        guard window.end > window.start else { throw SyncError.outOfWindow }
        let start = metric.isDaily ? SyncDates.day(window.start, zone: timeZone) : SyncDates.iso(window.start)
        let end = metric.isDaily ? SyncDates.day(window.end, zone: timeZone) : SyncDates.iso(window.end)
        let filter = "\(metric.filterField) >= \"\(start)\" AND \(metric.filterField) < \"\(end)\""
        let base = [URLQueryItem(name: "filter", value: filter), URLQueryItem(name: "pageSize", value: metric == .sleep ? "25" : "10000"),
                    URLQueryItem(name: "dataSourceFamily", value: "users/me/dataSourceFamilies/google-wearables")]
        var token: String?, seen: Set<String> = [], points: [JSONValue] = []
        for _ in 0..<200 {
            try Task.checkCancellation()
            var query = base
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page = try await get(path: "users/me/dataTypes/\(metric.rawValue)/dataPoints:reconcile", query: query)
            let collection = (page.object?["dataPoints"] ?? .array([])).array
            guard let collection, collection.allSatisfy({ $0.object != nil }), points.count + collection.count <= 1_000_000 else { throw SyncError.malformedResponse }
            points.append(contentsOf: collection)
            if page["nextPageToken"] == .null || page["nextPageToken"] == .string("") { return points }
            guard let next = page["nextPageToken"].string, next.count <= 16384, seen.insert(next).inserted else { throw SyncError.pagination }
            token = next
        }
        throw SyncError.pagination
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> JSONValue {
        // Paths originate solely in profileAge()/the closed HealthMetric enum.
        var components = URLComponents()
        components.scheme = "https"; components.host = "health.googleapis.com"; components.path = "/v4/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw SyncError.malformedResponse }
        var retriedAuthorization = false
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let token = try await accessToken()
            guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw SyncError.http(401) }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"; request.timeoutInterval = 45
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response: HTTPResult
            do { response = try await transport(request) }
            catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if let error = error as? SyncError { throw error }
                guard attempt < 3 else { throw SyncError.network }
                try await sleep(UInt64(1 << attempt) * 1_000_000_000)
                continue
            }
            try Task.checkCancellation()
            if let returned = response.responseURL, returned.scheme != "https" || returned.host != "health.googleapis.com" || returned.path != url.path { throw SyncError.redirect }
            if (300..<400).contains(response.status) { throw SyncError.redirect }
            if response.status == 401, !retriedAuthorization, attempt < 3 { retriedAuthorization = true; continue }
            if [429, 500, 502, 503, 504].contains(response.status), attempt < 3 {
                let seconds = min(30, max(1, Int(response.retryAfter ?? "") ?? (1 << attempt)))
                try await sleep(UInt64(seconds) * 1_000_000_000)
                continue
            }
            guard (200..<300).contains(response.status) else { throw SyncError.http(response.status) }
            guard response.data.count <= 25_000_000 else { throw SyncError.malformedResponse }
            guard let body = try? JSONDecoder().decode(JSONValue.self, from: response.data), body.object != nil else { throw SyncError.malformedResponse }
            return body
        }
        throw SyncError.network
    }
}
