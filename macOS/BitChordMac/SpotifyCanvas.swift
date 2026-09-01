import Combine
import Foundation
import WebKit

struct SpotifyCanvasTokens: Equatable, Sendable {
    let accessToken: String
    let clientToken: String?
}

protocol SpotifyCanvasTokenProviding: Sendable {
    func tokens() async -> SpotifyCanvasTokens?
}

protocol SpotifyCanvasHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionSpotifyCanvasTransport: SpotifyCanvasHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response)
    }
}

final class SpotifyCanvasCredentialStore: @unchecked Sendable {
    static let key = "spotify.spdc"
    private let store: any ScrobbleCredentialStoring

    init(service: String = "com.bitchord.mac.spotify-canvas") {
        store = KeychainScrobbleCredentialStore(service: service)
    }

    init(store: any ScrobbleCredentialStoring) {
        self.store = store
    }

    func cookie() -> String? { store.string(for: Self.key) }
    func setCookie(_ value: String?) throws { try store.set(value, for: Self.key) }
}

enum SpotifyCanvasSettingsError: LocalizedError {
    case invalidCookie

    var errorDescription: String? {
        "Paste only the value of Spotify's sp_dc cookie."
    }
}

@MainActor
final class SpotifyCanvasSettings: ObservableObject {
    @Published private(set) var isConfigured: Bool
    @Published private(set) var errorMessage: String?
    private let credentials: SpotifyCanvasCredentialStore

    init(credentials: SpotifyCanvasCredentialStore = SpotifyCanvasCredentialStore()) {
        self.credentials = credentials
        isConfigured = credentials.cookie()?.isEmpty == false
    }

    func save(_ rawValue: String) -> Bool {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "sp_dc=", options: .caseInsensitive) {
            value = String(value[range.upperBound...]).components(separatedBy: ";").first ?? ""
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 16, value.count <= 4_096,
              value.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0) &&
                    !CharacterSet.whitespacesAndNewlines.contains($0)
              }) else {
            errorMessage = SpotifyCanvasSettingsError.invalidCookie.localizedDescription
            return false
        }
        do {
            try credentials.setCookie(value)
            isConfigured = true
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove() {
        do {
            try credentials.setCookie(nil)
            isConfigured = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SpotifyHarvestedAccessToken: Equatable, Sendable {
    let token: String
    let expiresAt: Date
    let clientID: String?
}

protocol SpotifyAccessTokenHarvesting: Sendable {
    func harvest(cookie: String) async -> SpotifyHarvestedAccessToken?
}

struct WKSpotifyAccessTokenHarvester: SpotifyAccessTokenHarvesting {
    func harvest(cookie: String) async -> SpotifyHarvestedAccessToken? {
        await SpotifyWebTokenSession(cookie: cookie).run()
    }
}

@MainActor
private final class SpotifyWebTokenSession: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private static let handler = "BitChordSpotifyToken"
    private let cookie: String
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<SpotifyHarvestedAccessToken?, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(cookie: String) { self.cookie = cookie }

    func run() async -> SpotifyHarvestedAccessToken? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                start()
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finish(nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
    }

    private func start() {
        let controller = WKUserContentController()
        controller.add(self, name: Self.handler)
        controller.addUserScript(WKUserScript(
            source: Self.hookScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = CanvasUserAgent.browser
        self.webView = webView

        guard let spotifyCookie = HTTPCookie(properties: [
            .domain: ".spotify.com",
            .path: "/",
            .name: "sp_dc",
            .value: cookie,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(365 * 24 * 60 * 60)
        ]) else {
            finish(nil)
            return
        }
        configuration.websiteDataStore.httpCookieStore.setCookie(spotifyCookie) { [weak webView] in
            webView?.load(URLRequest(url: URL(string: "https://open.spotify.com/")!))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handler,
              let host = message.webView?.url?.host?.lowercased(),
              host == "spotify.com" || host.hasSuffix(".spotify.com"),
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["accessToken"] as? String,
              !token.isEmpty,
              (root["isAnonymous"] as? Bool) != true else { return }
        let milliseconds = (root["accessTokenExpirationTimestampMs"] as? NSNumber)?.doubleValue
        let expiry = milliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }
            .flatMap { $0 > Date() ? $0 : nil }
            ?? Date().addingTimeInterval(60 * 60)
        finish(SpotifyHarvestedAccessToken(
            token: token,
            expiresAt: expiry,
            clientID: root["clientId"] as? String
        ))
    }

    private func finish(_ result: SpotifyHarvestedAccessToken?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handler)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(returning: result)
    }

    private static let hookScript = #"""
    (function () {
      if (window.__bitchordSpotifyTokenHook) return;
      window.__bitchordSpotifyTokenHook = true;
      var report = function (body) {
        try { window.webkit.messageHandlers.BitChordSpotifyToken.postMessage(body); } catch (_) {}
      };
      var isToken = function (url) { return String(url || '').indexOf('/api/token') !== -1; };
      var originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function (input) {
          var url = input && input.url ? input.url : input;
          var result = originalFetch.apply(this, arguments);
          if (isToken(url)) result.then(function (response) {
            response.clone().text().then(report).catch(function () {});
          }).catch(function () {});
          return result;
        };
      }
      var originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__bitchordURL = url;
        return originalOpen.apply(this, arguments);
      };
      var originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        var request = this;
        request.addEventListener('load', function () {
          if (isToken(request.__bitchordURL)) report(request.responseText);
        });
        return originalSend.apply(this, arguments);
      };
    })();
    """#
}

actor SpotifyCanvasTokenManager: SpotifyCanvasTokenProviding {
    private struct SessionInfo: Sendable {
        let clientVersion: String
        let deviceID: String
    }

    private let credentials: SpotifyCanvasCredentialStore
    private let harvester: any SpotifyAccessTokenHarvesting
    private let transport: any SpotifyCanvasHTTPTransport
    private var activeCookie: String?
    private var access: SpotifyHarvestedAccessToken?
    private var clientToken: String?
    private var clientTokenExpiresAt = Date.distantPast
    private var sessionInfo: SessionInfo?

    init(
        credentials: SpotifyCanvasCredentialStore = SpotifyCanvasCredentialStore(),
        harvester: any SpotifyAccessTokenHarvesting = WKSpotifyAccessTokenHarvester(),
        transport: any SpotifyCanvasHTTPTransport = URLSessionSpotifyCanvasTransport()
    ) {
        self.credentials = credentials
        self.harvester = harvester
        self.transport = transport
    }

    func tokens() async -> SpotifyCanvasTokens? {
        guard let cookie = credentials.cookie()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cookie.isEmpty else { return nil }
        if activeCookie != cookie {
            activeCookie = cookie
            access = nil
            clientToken = nil
            clientTokenExpiresAt = .distantPast
        }
        let now = Date()
        let current: SpotifyHarvestedAccessToken
        if let access, now < access.expiresAt.addingTimeInterval(-30) {
            current = access
        } else {
            guard let harvested = await harvester.harvest(cookie: cookie) else { return nil }
            access = harvested
            current = harvested
        }
        let client = await validClientToken(access: current)
        return SpotifyCanvasTokens(accessToken: current.token, clientToken: client)
    }

    private func validClientToken(access: SpotifyHarvestedAccessToken) async -> String? {
        if let clientToken, Date() < clientTokenExpiresAt.addingTimeInterval(-30) { return clientToken }
        guard let clientID = access.clientID, !clientID.isEmpty,
              let session = await session() else { return nil }
        let payload: [String: Any] = ["client_data": [
            "client_version": session.clientVersion,
            "client_id": clientID,
            "js_sdk_data": [
                "device_brand": "Apple",
                "device_model": "Mac",
                "os": "osx",
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "device_id": session.deviceID,
                "device_type": "computer"
            ]
        ]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "https://clienttoken.spotify.com/v1/clienttoken") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(CanvasUserAgent.browser, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await transport.data(for: request),
              (200..<300).contains(response.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["response_type"] as? String == "RESPONSE_GRANTED_TOKEN_RESPONSE",
              let granted = root["granted_token"] as? [String: Any],
              let token = granted["token"] as? String else { return nil }
        let ttl = (granted["expires_after_seconds"] as? NSNumber)?.doubleValue ?? 3_600
        clientToken = token
        clientTokenExpiresAt = Date().addingTimeInterval(ttl)
        return token
    }

    private func session() async -> SessionInfo? {
        if let sessionInfo { return sessionInfo }
        guard let url = URL(string: "https://open.spotify.com/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(CanvasUserAgent.browser, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await transport.data(for: request),
              (200..<300).contains(response.statusCode),
              let html = String(data: data, encoding: .utf8),
              let encoded = html.firstCapture(#"<script id="appServerConfig" type="text/plain">([^<]+)</script>"#),
              let decoded = Data(base64Encoded: encoded),
              let root = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let version = root["clientVersion"] as? String else { return nil }
        let cookieHeader = response.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        let deviceID = cookieHeader.firstCapture(#"sp_t=([^;,]+)"#) ?? UUID().uuidString
        let session = SessionInfo(clientVersion: version, deviceID: deviceID)
        sessionInfo = session
        return session
    }
}

struct SpotifyCanvasHit: Equatable, Sendable {
    let id: String?
    let url: String
    let trackURI: String?
}

actor SpotifyCanvasProvider: CanvasProvider {
    private struct TrackHit: Sendable {
        let uri: String
        let title: String
        let artist: String
        let album: String?
    }

    private static let searchURL = "https://api.spotify.com/v1/search"
    private static let albumURL = "https://api.spotify.com/v1/albums"
    private static let canvasURL = "https://spclient.wg.spotify.com/canvaz-cache/v0/canvases"
    private static let pathfinderURL = "https://api-partner.spotify.com/pathfinder/v1/query"
    private static let pathfinderHash = "bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428"
    private static let appUserAgent = "Spotify/9.0.34.593 iOS/18.4 (iPhone15,3)"

    private let tokenProvider: any SpotifyCanvasTokenProviding
    private let transport: any SpotifyCanvasHTTPTransport

    init(
        tokenProvider: any SpotifyCanvasTokenProviding = SpotifyCanvasTokenManager(),
        transport: any SpotifyCanvasHTTPTransport = URLSessionSpotifyCanvasTransport()
    ) {
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    func canvas(title: String, artist: String, album: String?) async -> CanvasArtwork? {
        guard let tokens = await tokenProvider.tokens() else { return nil }
        let hit: TrackHit?
        if let pathfinder = await pathfinderHit(title: title, artist: artist, album: album, tokens: tokens) {
            hit = pathfinder
        } else {
            hit = await restTrackHit(title: title, artist: artist, album: album, tokens: tokens)
        }
        guard let hit,
              let url = await canvasURL(trackURI: hit.uri, tokens: tokens) else { return nil }
        return CanvasArtwork(
            url: url,
            title: hit.title,
            artist: hit.artist,
            album: hit.album,
            source: .spotify
        )
    }

    func albumCanvas(album: String, artist: String) async -> CanvasArtwork? {
        guard let tokens = await tokenProvider.tokens(),
              let url = Self.searchURL(query: "\(album) \(artist)", type: "album"),
              let root = await json(GET: url, headers: authHeaders(tokens)),
              let albums = root["albums"] as? [String: Any],
              let rows = albums["items"] as? [[String: Any]] else { return nil }
        for row in rows {
            guard let name = row["name"] as? String,
                  let artistRows = row["artists"] as? [[String: Any]] else { continue }
            let credits = artistRows.compactMap { $0["name"] as? String }
            guard Self.isMatch(name: name, artists: credits, wantedName: album, wantedArtist: artist),
                  let id = row["id"] as? String,
                  let trackURI = await firstTrackURI(albumID: id, tokens: tokens),
                  let clip = await canvasURL(trackURI: trackURI, tokens: tokens) else { continue }
            return CanvasArtwork(
                url: clip,
                title: name,
                artist: credits.joined(separator: ", "),
                album: name,
                source: .spotify
            )
        }
        return nil
    }

    private func pathfinderHit(
        title: String,
        artist: String,
        album: String?,
        tokens: SpotifyCanvasTokens
    ) async -> TrackHit? {
        guard let client = tokens.clientToken else { return nil }
        let variables: [String: Any] = [
            "searchTerm": [title, artist, album].compactMap { $0 }.joined(separator: " "),
            "offset": 0, "limit": 10, "numberOfTopResults": 5,
            "includeAudiobooks": false, "includePreReleases": false
        ]
        let extensions: [String: Any] = ["persistedQuery": ["version": 1, "sha256Hash": Self.pathfinderHash]]
        guard let variablesData = try? JSONSerialization.data(withJSONObject: variables),
              let variablesString = String(data: variablesData, encoding: .utf8),
              let extensionsData = try? JSONSerialization.data(withJSONObject: extensions),
              let extensionsString = String(data: extensionsData, encoding: .utf8),
              var components = URLComponents(string: Self.pathfinderURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "operationName", value: "searchTracks"),
            URLQueryItem(name: "variables", value: variablesString),
            URLQueryItem(name: "extensions", value: extensionsString)
        ]
        guard let url = components.url,
              let root = await json(GET: url, headers: [
                "Authorization": "Bearer \(tokens.accessToken)",
                "Client-Token": client,
                "App-platform": "WebPlayer",
                "Accept": "application/json",
                "User-Agent": CanvasUserAgent.browser
              ]),
              let data = (((((root["data"] as? [String: Any])?["searchV2"] as? [String: Any])?["tracksV2"] as? [String: Any])?["items"] as? [[String: Any]])?.first?["item"] as? [String: Any])?["data"] as? [String: Any] else {
            return nil
        }
        let uri = data["uri"] as? String ?? (data["id"] as? String).map { "spotify:track:\($0)" }
        guard let uri else { return nil }
        return TrackHit(uri: uri, title: title, artist: artist, album: album)
    }

    private func restTrackHit(
        title: String,
        artist: String,
        album: String?,
        tokens: SpotifyCanvasTokens
    ) async -> TrackHit? {
        guard let url = Self.searchURL(
            query: [title, artist, album].compactMap { $0 }.joined(separator: " "),
            type: "track"
        ), let root = await json(GET: url, headers: authHeaders(tokens)),
           let tracks = root["tracks"] as? [String: Any],
           let rows = tracks["items"] as? [[String: Any]] else { return nil }
        for row in rows {
            guard let name = row["name"] as? String,
                  let artists = row["artists"] as? [[String: Any]],
                  let uri = row["uri"] as? String else { continue }
            let credits = artists.compactMap { $0["name"] as? String }
            guard Self.isMatch(name: name, artists: credits, wantedName: title, wantedArtist: artist) else { continue }
            let albumName = (row["album"] as? [String: Any])?["name"] as? String
            return TrackHit(uri: uri, title: name, artist: credits.joined(separator: ", "), album: albumName)
        }
        return nil
    }

    private func firstTrackURI(albumID: String, tokens: SpotifyCanvasTokens) async -> String? {
        var components = URLComponents(string: "\(Self.albumURL)/\(albumID)/tracks")
        components?.queryItems = [URLQueryItem(name: "limit", value: "1")]
        guard let url = components?.url,
              let root = await json(GET: url, headers: authHeaders(tokens)),
              let rows = root["items"] as? [[String: Any]] else { return nil }
        return rows.first?["uri"] as? String
    }

    private func canvasURL(trackURI: String, tokens: SpotifyCanvasTokens) async -> URL? {
        guard let url = URL(string: Self.canvasURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Self.encodeCanvasRequest(trackURI: trackURI)
        request.timeoutInterval = 15
        authHeaders(tokens).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("application/protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("application/protobuf", forHTTPHeaderField: "Accept")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.appUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await transport.data(for: request),
              (200..<300).contains(response.statusCode) else { return nil }
        let hits = Self.decodeCanvasResponse(data)
        let selected = hits.first(where: { $0.trackURI == trackURI }) ?? hits.first
        if let selected, let url = URL(string: selected.url) { return url }
        guard let text = String(data: data, encoding: .isoLatin1),
              let raw = text.firstCapture(#"(https://[^\"'\s\x00-\x1F]+\.cnvs\.mp4)"#) else { return nil }
        return URL(string: raw)
    }

    private func json(GET url: URL, headers: [String: String]) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await transport.data(for: request),
              (200..<300).contains(response.statusCode) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func authHeaders(_ tokens: SpotifyCanvasTokens) -> [String: String] {
        var headers = [
            "Authorization": "Bearer \(tokens.accessToken)",
            "User-Agent": CanvasUserAgent.browser
        ]
        if let client = tokens.clientToken { headers["Client-Token"] = client }
        return headers
    }

    private static func searchURL(query: String, type: String) -> URL? {
        var components = URLComponents(string: searchURL)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "limit", value: "10")
        ]
        return components?.url
    }

    private static func isMatch(
        name: String,
        artists: [String],
        wantedName: String,
        wantedArtist: String
    ) -> Bool {
        guard name.canvasNormalized == wantedName.canvasNormalized else { return false }
        let wanted = CanvasMatching.splitArtists(wantedArtist)
        let credited = artists.map(\.canvasNormalized).filter { !$0.isEmpty }
        return !wanted.isEmpty && !credited.isEmpty && wanted.allSatisfy(credited.contains)
    }

    static func encodeCanvasRequest(trackURI: String) -> Data {
        let nested = field(number: 1, bytes: Data(trackURI.utf8))
        return field(number: 1, bytes: nested)
    }

    static func decodeCanvasResponse(_ data: Data) -> [SpotifyCanvasHit] {
        lengthDelimitedFields(in: data, number: 1).compactMap(decodeCanvas)
    }

    private static func decodeCanvas(_ data: Data) -> SpotifyCanvasHit? {
        let id = lengthDelimitedFields(in: data, number: 1).first.flatMap { String(data: $0, encoding: .utf8) }
        let url = lengthDelimitedFields(in: data, number: 2).first.flatMap { String(data: $0, encoding: .utf8) }
        let track = lengthDelimitedFields(in: data, number: 5).first.flatMap { String(data: $0, encoding: .utf8) }
        return url.map { SpotifyCanvasHit(id: id, url: $0, trackURI: track) }
    }

    private static func field(number: Int, bytes: Data) -> Data {
        var data = encodeVarint(UInt64(number << 3 | 2))
        data.append(encodeVarint(UInt64(bytes.count)))
        data.append(bytes)
        return data
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }

    private static func lengthDelimitedFields(in data: Data, number: Int) -> [Data] {
        let bytes = [UInt8](data)
        var index = 0
        var fields: [Data] = []
        while index < bytes.count, let tag = readVarint(bytes, index: &index) {
            let fieldNumber = Int(tag >> 3)
            let wire = Int(tag & 7)
            switch wire {
            case 0:
                guard readVarint(bytes, index: &index) != nil else { return fields }
            case 1:
                index = min(bytes.count, index + 8)
            case 2:
                guard let length = readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index) else { return fields }
                let end = index + Int(length)
                if fieldNumber == number { fields.append(Data(bytes[index..<end])) }
                index = end
            case 5:
                index = min(bytes.count, index + 4)
            default:
                return fields
            }
        }
        return fields
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}

extension String {
    fileprivate func firstCapture(_ pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: self, range: NSRange(startIndex..<endIndex, in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
