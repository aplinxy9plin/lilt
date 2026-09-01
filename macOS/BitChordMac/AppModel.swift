import AVFoundation
import AudioToolbox
import Combine
import Foundation
import MediaPlayer
import AppKit
import Network
import os
import UniformTypeIdentifiers

enum AppThemeMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

final class AuthStore: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let cookieKey = "BitChord.youtubeCookie"

    var cookie: String? {
        get { defaults.string(forKey: cookieKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: cookieKey) }
            else { defaults.removeObject(forKey: cookieKey) }
        }
    }

    static func hasAPISID(_ cookieHeader: String) -> Bool {
        cookieHeader.split(separator: ";").contains { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            return ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"].contains(name) &&
                !parts[1].trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func signOut() {
        cookie = nil
    }
}

@MainActor
final class PlaybackSettings: ObservableObject {
    @Published var themeMode: AppThemeMode {
        didSet { defaults.set(themeMode.rawValue.uppercased(), forKey: Self.themeModeKey) }
    }
    @Published var autoplay: Bool {
        didSet {
            defaults.set(autoplay, forKey: Self.autoplayKey)
            notifyAutoplayChange()
        }
    }
    @Published var dontRepeatSuggestions: Bool {
        didSet {
            defaults.set(dontRepeatSuggestions, forKey: Self.dontRepeatSuggestionsKey)
            notifyAutoplayChange()
        }
    }
    @Published var unmeteredQuality: AudioQuality {
        didSet {
            defaults.set(unmeteredQuality.rawValue, forKey: Self.unmeteredQualityKey)
            notifyChange()
        }
    }
    @Published var meteredQuality: AudioQuality {
        didSet {
            defaults.set(meteredQuality.rawValue, forKey: Self.meteredQualityKey)
            notifyChange()
        }
    }
    @Published var skipSilence: Bool {
        didSet {
            defaults.set(skipSilence, forKey: Self.skipSilenceKey)
            notifyChange()
        }
    }
    @Published var spatialAudio: Bool {
        didSet {
            defaults.set(spatialAudio, forKey: Self.spatialAudioKey)
            onSpatialAudioChange?(spatialAudio)
        }
    }
    @Published var convertVideoToAudio: Bool {
        didSet {
            defaults.set(convertVideoToAudio, forKey: Self.convertVideoToAudioKey)
            onVideoAudioConversionChange?(convertVideoToAudio)
        }
    }
    @Published var playbackSpeed: Double {
        didSet {
            let clamped = Self.clampedPlaybackSpeed(playbackSpeed)
            if playbackSpeed != clamped {
                playbackSpeed = clamped
                return
            }
            defaults.set(playbackSpeed, forKey: Self.playbackSpeedKey)
            onPlaybackSpeedChange?(playbackSpeed)
        }
    }
    @Published var crossfadeSeconds: Int {
        didSet {
            let clamped = min(max(crossfadeSeconds, 0), 12)
            if crossfadeSeconds != clamped {
                crossfadeSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Self.crossfadeKey)
            notifyChange()
        }
    }
    @Published var smartFadeEnabled: Bool {
        didSet {
            defaults.set(smartFadeEnabled, forKey: Self.smartFadeKey)
            onAutomixChange?(smartFadeEnabled)
        }
    }
    @Published var showNerdStats: Bool {
        didSet { defaults.set(showNerdStats, forKey: Self.showNerdStatsKey) }
    }
    @Published var hideVolumeBar: Bool {
        didSet { defaults.set(hideVolumeBar, forKey: Self.hideVolumeBarKey) }
    }
    @Published var wifiOnlyDownloads: Bool {
        didSet { defaults.set(wifiOnlyDownloads, forKey: Self.wifiOnlyDownloadsKey) }
    }
    @Published var dynamicArtworkTheme: Bool {
        didSet { defaults.set(dynamicArtworkTheme, forKey: Self.dynamicArtworkThemeKey) }
    }
    @Published var reduceAnimation: Bool {
        didSet { defaults.set(reduceAnimation, forKey: Self.reduceAnimationKey) }
    }
    @Published var reduceDynamicBlur: Bool {
        didSet { defaults.set(reduceDynamicBlur, forKey: Self.reduceDynamicBlurKey) }
    }
    @Published var fullBleedArtwork: Bool {
        didSet { defaults.set(fullBleedArtwork, forKey: Self.fullBleedArtworkKey) }
    }
    @Published var animatedCanvas: Bool {
        didSet { defaults.set(animatedCanvas, forKey: Self.animatedCanvasKey) }
    }
    @Published var canvasOverMetered: Bool {
        didSet { defaults.set(canvasOverMetered, forKey: Self.canvasOverMeteredKey) }
    }
    @Published var audioCacheLimitBytes: Int64 {
        didSet {
            let clamped = Self.clampedAudioCacheLimit(audioCacheLimitBytes)
            if audioCacheLimitBytes != clamped {
                audioCacheLimitBytes = clamped
                return
            }
            defaults.set(clamped, forKey: Self.audioCacheLimitKey)
            onAudioCacheLimitChange?(clamped)
        }
    }
    @Published private(set) var networkIsMetered = false

    var onChange: ((AudioQuality, Bool, Int) -> Void)?
    var onAutomixChange: ((Bool) -> Void)?
    var onAutoplayChange: ((Bool, Bool) -> Void)?
    var onSpatialAudioChange: ((Bool) -> Void)?
    var onVideoAudioConversionChange: ((Bool) -> Void)?
    var onPlaybackSpeedChange: ((Double) -> Void)?
    var onAudioCacheLimitChange: ((Int64) -> Void)?

    static let supportedRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private static let autoplayKey = "autoplay"
    private static let themeModeKey = "theme_mode"
    private static let dontRepeatSuggestionsKey = "dont_repeat_suggestions"
    private static let unmeteredQualityKey = "BitChord.playbackQuality.unmetered"
    private static let meteredQualityKey = "BitChord.playbackQuality.metered"
    private static let skipSilenceKey = "BitChord.skipSilence"
    private static let spatialAudioKey = "spatial_audio"
    private static let convertVideoToAudioKey = "convert_video_to_audio"
    private static let playbackSpeedKey = "playback_speed"
    private static let crossfadeKey = "BitChord.crossfadeSeconds"
    private static let smartFadeKey = "smart_fade_enabled"
    private static let automixOptInVersionKey = "BitChord.automixOptInVersion"
    private static let currentAutomixOptInVersion = 1
    private static let showNerdStatsKey = "BitChord.showNerdStats"
    private static let hideVolumeBarKey = "hide_volume_bar"
    private static let wifiOnlyDownloadsKey = "wifi_only_downloads"
    private static let dynamicArtworkThemeKey = "BitChord.dynamicArtworkTheme"
    private static let reduceAnimationKey = "BitChord.reduceAnimation"
    private static let reduceDynamicBlurKey = "reduce_dynamic_blur"
    private static let fullBleedArtworkKey = "full_bleed_artwork"
    private static let animatedCanvasKey = "animated_canvas"
    private static let canvasOverMeteredKey = "canvas_over_cellular"
    private static let audioCacheLimitKey = "audio_cache_limit_bytes"

    private let defaults: UserDefaults
    private let pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.bitchord.mac.network-quality")

    var effectiveQuality: AudioQuality {
        networkIsMetered ? meteredQuality : unmeteredQuality
    }

    var downloadsAllowedNow: Bool {
        Self.downloadsAllowed(wifiOnly: wifiOnlyDownloads, networkIsMetered: networkIsMetered)
    }

    init(defaults: UserDefaults = .standard, monitorNetwork: Bool = true) {
        self.defaults = defaults
        themeMode = defaults.string(forKey: Self.themeModeKey)
            .flatMap { AppThemeMode(rawValue: $0.lowercased()) } ?? .dark
        autoplay = defaults.object(forKey: Self.autoplayKey) as? Bool ?? true
        dontRepeatSuggestions = defaults.object(forKey: Self.dontRepeatSuggestionsKey) as? Bool ?? false
        unmeteredQuality = defaults.string(forKey: Self.unmeteredQualityKey)
            .flatMap(AudioQuality.init(rawValue:)) ?? .high
        meteredQuality = defaults.string(forKey: Self.meteredQualityKey)
            .flatMap(AudioQuality.init(rawValue:)) ?? .high
        skipSilence = defaults.object(forKey: Self.skipSilenceKey) as? Bool ?? false
        spatialAudio = defaults.object(forKey: Self.spatialAudioKey) as? Bool ?? false
        convertVideoToAudio = defaults.object(forKey: Self.convertVideoToAudioKey) as? Bool ?? true
        playbackSpeed = Self.clampedPlaybackSpeed(
            (defaults.object(forKey: Self.playbackSpeedKey) as? NSNumber)?.doubleValue ?? 1
        )
        crossfadeSeconds = min(max(defaults.integer(forKey: Self.crossfadeKey), 0), 12)
        let hasExplicitAutomixOptIn = defaults.integer(forKey: Self.automixOptInVersionKey)
            >= Self.currentAutomixOptInVersion
        smartFadeEnabled = hasExplicitAutomixOptIn
            ? defaults.object(forKey: Self.smartFadeKey) as? Bool ?? false
            : false
        if !hasExplicitAutomixOptIn {
            // Earlier builds could leave Automix enabled without making the
            // skip-ahead behavior discoverable. Require a fresh explicit opt-in.
            defaults.set(false, forKey: Self.smartFadeKey)
            defaults.set(Self.currentAutomixOptInVersion, forKey: Self.automixOptInVersionKey)
        }
        showNerdStats = defaults.object(forKey: Self.showNerdStatsKey) as? Bool ?? false
        hideVolumeBar = defaults.object(forKey: Self.hideVolumeBarKey) as? Bool ?? false
        wifiOnlyDownloads = defaults.object(forKey: Self.wifiOnlyDownloadsKey) as? Bool ?? true
        dynamicArtworkTheme = defaults.object(forKey: Self.dynamicArtworkThemeKey) as? Bool ?? true
        reduceAnimation = defaults.object(forKey: Self.reduceAnimationKey) as? Bool ?? false
        reduceDynamicBlur = defaults.object(forKey: Self.reduceDynamicBlurKey) as? Bool ?? false
        fullBleedArtwork = defaults.object(forKey: Self.fullBleedArtworkKey) as? Bool ?? true
        animatedCanvas = defaults.object(forKey: Self.animatedCanvasKey) as? Bool ?? true
        canvasOverMetered = defaults.object(forKey: Self.canvasOverMeteredKey) as? Bool ?? false
        audioCacheLimitBytes = Self.clampedAudioCacheLimit(
            (defaults.object(forKey: Self.audioCacheLimitKey) as? NSNumber)?.int64Value
                ?? AudioStreamCache.defaultLimitBytes
        )

        if monitorNetwork {
            let monitor = NWPathMonitor()
            pathMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let isMetered = path.isExpensive || path.isConstrained
                Task { @MainActor [weak self] in
                    guard let self, networkIsMetered != isMetered else { return }
                    networkIsMetered = isMetered
                    notifyChange()
                }
            }
            monitor.start(queue: monitorQueue)
        } else {
            pathMonitor = nil
        }
    }

    deinit {
        pathMonitor?.cancel()
    }

    nonisolated static func downloadsAllowed(wifiOnly: Bool, networkIsMetered: Bool) -> Bool {
        !wifiOnly || !networkIsMetered
    }

    func applyCurrentSettings() {
        notifyChange()
        onAutomixChange?(smartFadeEnabled)
        notifyAutoplayChange()
        onSpatialAudioChange?(spatialAudio)
        onVideoAudioConversionChange?(convertVideoToAudio)
        onPlaybackSpeedChange?(playbackSpeed)
        onAudioCacheLimitChange?(audioCacheLimitBytes)
    }

    static func clampedPlaybackSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0.5), 2)
    }

    private func notifyChange() {
        onChange?(effectiveQuality, skipSilence, crossfadeSeconds)
    }

    private func notifyAutoplayChange() {
        onAutoplayChange?(autoplay, dontRepeatSuggestions)
    }

    private static func clampedAudioCacheLimit(_ bytes: Int64) -> Int64 {
        min(max(bytes, AudioStreamCache.defaultLimitBytes), AudioStreamCache.maximumLimitBytes)
    }
}

enum CrossfadeCurve {
    static func gains(at progress: Double) -> (outgoing: Float, incoming: Float) {
        let fraction = min(max(progress, 0), 1)
        let angle = fraction * .pi / 2
        return (Float(cos(angle)), Float(sin(angle)))
    }

    static func duration(
        configuredSeconds: Int,
        outgoingDuration: TimeInterval,
        incomingDuration: TimeInterval?
    ) -> TimeInterval {
        guard configuredSeconds > 0, outgoingDuration > 0 else { return 0 }
        let incomingLimit = incomingDuration.map { max(0, $0 / 3) } ?? 12
        return min(
            TimeInterval(min(configuredSeconds, 12)),
            outgoingDuration / 3,
            incomingLimit
        )
    }
}

/// AVPlayer does not consistently forward `AVURLAssetHTTPHeaderFieldsKey` on
/// macOS. YouTube's CDN then rejects an otherwise valid media URL. This tiny
/// loopback proxy keeps AVPlayer on ordinary HTTP while URLSession forwards
/// every Range request with the resolver's required headers.
final class LocalStreamProxy: @unchecked Sendable {
    enum ProxyError: Error {
        case unavailable
    }

    private let upstreamURL: URL
    private let upstreamHeaders: [String: String]
    private let logger = Logger(subsystem: "com.bitchord.mac", category: "StreamProxy")
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.bitchord.mac.stream-proxy")
    private let pathToken = UUID().uuidString
    // Same size proven by the Kotlin ChunkedDataSource: large enough to
    // amortize each request while still avoiding googlevideo's paced whole-file
    // response and allowing a quick retry on a refused client.
    fileprivate static let maximumUpstreamChunkLength: Int64 = 2 * 1_024 * 1_024
    private let requestLock = NSLock()
    private var activeRequests: [UUID: ForwardedRequest] = [:]

    init(upstreamURL: URL, headers: [String: String]) throws {
        self.upstreamURL = upstreamURL
        upstreamHeaders = headers
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let startState = ProxyStartState()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let self, let port = listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(pathToken)/audio.m4a") else {
                        if startState.claim() {
                            continuation.resume(throwing: ProxyError.unavailable)
                        }
                        return
                    }
                    if startState.claim() {
                        continuation.resume(returning: url)
                    }
                case .failed(let error):
                    if startState.claim() {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    if startState.claim() {
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        requestLock.lock()
        let requests = Array(activeRequests.values)
        activeRequests.removeAll()
        requestLock.unlock()
        requests.forEach { $0.cancel() }
    }

    deinit {
        stop()
    }

    private func accept(_ connection: NWConnection) {
        logger.info("Accepted local AVPlayer connection")
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return }
            var requestData = buffer
            if let data { requestData.append(data) }
            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil {
                handle(requestData, on: connection)
            } else if error == nil, !complete, requestData.count < 65_536 {
                receiveRequest(on: connection, buffer: requestData)
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        guard let requestText = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }
        let lines = requestText.components(separatedBy: "\r\n")
        let requestParts = lines.first?.split(separator: " ") ?? []
        guard requestParts.count >= 2,
              requestParts[1].contains(pathToken) else {
            logger.error("Rejected malformed local stream request")
            sendSimpleResponse(status: 404, message: "Not Found", on: connection)
            return
        }

        var request = URLRequest(url: upstreamURL)
        request.httpMethod = requestParts[0].uppercased()
        request.timeoutInterval = 60
        var clientRange: ProxyByteRange?
        for (name, value) in upstreamHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if name.caseInsensitiveCompare("Range") == .orderedSame ||
                name.caseInsensitiveCompare("If-Range") == .orderedSame {
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if name.caseInsensitiveCompare("Range") == .orderedSame {
                    let cappedValue = Self.cappedRange(value)
                    clientRange = ProxyByteRange(cappedValue)
                    request.setValue(cappedValue, forHTTPHeaderField: name)
                } else {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }
        }
        let safeHeaderNames = request.allHTTPHeaderFields?.keys
            .filter { !$0.lowercased().contains("cookie") && !$0.lowercased().contains("authorization") }
            .sorted()
            .joined(separator: ",") ?? "none"
        logger.info("Forwarding \(request.httpMethod ?? "GET", privacy: .public) range \(request.value(forHTTPHeaderField: "Range") ?? "none", privacy: .public), headers \(safeHeaderNames, privacy: .public)")

        let identifier = UUID()
        let forwarded = ForwardedRequest(
            request: request,
            requestedRange: clientRange,
            connection: connection,
            onFinish: { [weak self] in self?.removeRequest(identifier) }
        )
        requestLock.lock()
        activeRequests[identifier] = forwarded
        requestLock.unlock()
        forwarded.start()
    }

    /// YouTube's media CDN can reject the whole-file byte range AVPlayer asks
    /// for after probing an MP4. Returning a smaller valid 206 response makes
    /// AVPlayer continue with normal sequential range requests, matching the
    /// chunked behavior of ExoPlayer on Android.
    static func cappedRange(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes="),
              !value.contains(",") else { return value }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]), start >= 0 else { return value }
        let requestedEnd = Int64(bounds[1])
        let maximumEnd = start + maximumUpstreamChunkLength - 1
        let end = min(requestedEnd ?? maximumEnd, maximumEnd)
        guard end >= start else { return value }
        return "bytes=\(start)-\(end)"
    }

    private func removeRequest(_ identifier: UUID) {
        requestLock.lock()
        activeRequests.removeValue(forKey: identifier)
        requestLock.unlock()
    }

    private func sendSimpleResponse(status: Int, message: String, on connection: NWConnection) {
        let body = Data(message.utf8)
        let response = "HTTP/1.1 \(status) \(message)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class ProxyStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private struct ProxyByteRange: Sendable {
    let start: Int64
    let end: Int64?

    init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes="), !value.contains(",") else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2, let start = Int64(bounds[0]), start >= 0 else { return nil }
        let end = Int64(bounds[1])
        if let end, end < start { return nil }
        self.start = start
        self.end = end
    }
}

private final class ForwardedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.bitchord.mac", category: "StreamProxy")
    private let request: URLRequest
    private let requestedRange: ProxyByteRange?
    private let connection: NWConnection
    private let onFinish: () -> Void
    private var session: URLSession?
    private var responseSent = false
    private var completed = false
    private var activeChunkEnd: Int64?
    private var deliveryEnd: Int64?
    private var resourceLength: Int64?

    init(
        request: URLRequest,
        requestedRange: ProxyByteRange?,
        connection: NWConnection,
        onFinish: @escaping () -> Void
    ) {
        self.request = request
        self.requestedRange = requestedRange
        deliveryEnd = requestedRange?.end
        resourceLength = request.url.flatMap(Self.resourceLengthHint)
        self.connection = connection
        self.onFinish = onFinish
    }

    func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: operationQueue)
        self.session = session
        startUpstreamTask(at: requestedRange?.start)
    }

    func cancel() {
        session?.invalidateAndCancel()
        connection.cancel()
        finish()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            if let response = response as? HTTPURLResponse {
                logger.error("Upstream rejected stream request with HTTP \(response.statusCode, privacy: .public)")
            } else {
                logger.error("Upstream stream response was not HTTP")
            }
            completionHandler(.cancel)
            sendGatewayError()
            return
        }
        logger.info("Upstream stream response HTTP \(response.statusCode, privacy: .public), bytes \(response.expectedContentLength, privacy: .public), range \(response.value(forHTTPHeaderField: "Content-Range") ?? "none", privacy: .public)")

        if let total = Self.resourceLength(from: response) {
            resourceLength = total
            if requestedRange != nil {
                deliveryEnd = min(deliveryEnd ?? (total - 1), total - 1)
            }
        }

        guard !responseSent else {
            completionHandler(.allow)
            return
        }

        var header = "HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(for: response.statusCode))\r\n"
        let forwardedHeaderNames = [
            "Content-Type", "Accept-Ranges",
            "Cache-Control", "ETag", "Last-Modified"
        ]
        for name in forwardedHeaderNames {
            if let value = response.value(forHTTPHeaderField: name) {
                header += "\(name): \(value)\r\n"
            }
        }
        if let requestedRange, let deliveryEnd {
            header += "Content-Length: \(deliveryEnd - requestedRange.start + 1)\r\n"
            if let resourceLength {
                header += "Content-Range: bytes \(requestedRange.start)-\(deliveryEnd)/\(resourceLength)\r\n"
            } else if let value = response.value(forHTTPHeaderField: "Content-Range") {
                header += "Content-Range: \(value)\r\n"
            }
        } else {
            for name in ["Content-Length", "Content-Range"] {
                if let value = response.value(forHTTPHeaderField: name) {
                    header += "\(name): \(value)\r\n"
                }
            }
        }
        header += "Connection: close\r\n\r\n"
        responseSent = true
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.cancel() }
        })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            logger.error("Upstream stream task failed: \(error.localizedDescription, privacy: .public)")
            if !responseSent {
                sendGatewayError()
            } else {
                completeConnection()
            }
            return
        }

        if let activeChunkEnd, let deliveryEnd, activeChunkEnd < deliveryEnd {
            startUpstreamTask(at: activeChunkEnd + 1)
            return
        }
        completeConnection()
    }

    private func startUpstreamTask(at start: Int64?) {
        guard let session else { return }
        var chunkRequest = request
        if let requestedRange, let start {
            let finalEnd = deliveryEnd ?? requestedRange.end
            let maximumEnd = start + LocalStreamProxy.maximumUpstreamChunkLength - 1
            var chunkEnd = min(finalEnd ?? maximumEnd, maximumEnd)
            // A number of YouTube device clients accept bounded slices but
            // refuse a Range that is exactly the complete resource. Leave at
            // least one byte for a second request so even a short low-quality
            // AAC file retains genuinely chunked transport.
            if start == 0,
               requestedRange.start == 0,
               let finalEnd,
               let resourceLength,
               finalEnd == resourceLength - 1,
               finalEnd - start > 4_096,
               chunkEnd == finalEnd {
                chunkEnd = finalEnd - 1
            }
            activeChunkEnd = chunkEnd
            chunkRequest.setValue("bytes=\(start)-\(chunkEnd)", forHTTPHeaderField: "Range")
            logger.info("Fetching upstream chunk bytes=\(start, privacy: .public)-\(chunkEnd, privacy: .public)")
        } else {
            activeChunkEnd = nil
        }
        session.dataTask(with: chunkRequest).resume()
    }

    private func completeConnection() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.finish()
        })
    }

    private func sendGatewayError() {
        guard !responseSent else { return }
        responseSent = true
        let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.finish()
        })
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        session?.finishTasksAndInvalidate()
        session = nil
        onFinish()
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        default: "OK"
        }
    }

    private static func resourceLength(from response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...])
    }

    private static func resourceLengthHint(from url: URL) -> Int64? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "clen" })?
            .value
            .flatMap(Int64.init)
    }
}

/// Mirrors the web player's signed playback telemetry so listening in
/// BitChord updates the user's YouTube Music history and recommendations.
/// Failures are deliberately best-effort and never interrupt audio.
@MainActor
final class PlaybackHistoryTracker {
    private let logger = Logger(subsystem: "com.bitchord.mac", category: "PlaybackHistory")
    private final class Session {
        let videoID: String
        let cpn: String
        let urls: PlaybackTrackingURLs
        var reportedSeconds = 0
        var flushingToSeconds = 0
        var atrSent = false

        init(videoID: String, cpn: String, urls: PlaybackTrackingURLs) {
            self.videoID = videoID
            self.cpn = cpn
            self.urls = urls
        }
    }

    var onRegisteredPlay: (() -> Void)?

    private let api: any PlaybackHistoryAPI
    private let reportIntervalSeconds: Int
    private let openAttempts: Int
    private let retryNanoseconds: UInt64
    private var session: Session?
    private var openingVideoID: String?
    private var openingTask: Task<Void, Never>?
    private var generation = UUID()

    init(
        api: any PlaybackHistoryAPI,
        reportIntervalSeconds: Int = 30,
        openAttempts: Int = 3,
        retryNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.api = api
        self.reportIntervalSeconds = reportIntervalSeconds
        self.openAttempts = openAttempts
        self.retryNanoseconds = retryNanoseconds
    }

    func onPlaying(videoID: String) {
        guard api.isAuthenticated, Self.isYouTubeVideoID(videoID) else { return }
        guard session?.videoID != videoID, openingVideoID != videoID else { return }
        logger.debug("Opening signed history session for \(videoID, privacy: .public)")
        if session != nil { onTrackChanged(position: 0) }

        openingTask?.cancel()
        generation = UUID()
        let requestGeneration = generation
        openingVideoID = videoID
        openingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == requestGeneration, openingVideoID == videoID {
                    openingVideoID = nil
                    openingTask = nil
                }
            }
            for attempt in 0..<max(1, openAttempts) {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                do {
                    guard let urls = try await api.playbackTracking(for: videoID) else {
                        logger.warning("Player returned no tracking block for \(videoID, privacy: .public)")
                        return
                    }
                    let cpn = Self.makeCPN()
                    try await api.pingPlayback(urls.playbackURL, cpn: cpn)
                    guard !Task.isCancelled, generation == requestGeneration else { return }
                    session = Session(videoID: videoID, cpn: cpn, urls: urls)
                    logger.info("History entry registered for \(videoID, privacy: .public)")
                    onRegisteredPlay?()
                    return
                } catch {
                    logger.warning(
                        "History registration attempt \(attempt + 1, privacy: .public) failed for \(videoID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    guard attempt + 1 < max(1, openAttempts) else { return }
                    do {
                        try await Task.sleep(nanoseconds: retryNanoseconds)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    func onProgress(videoID: String, position: TimeInterval) {
        guard let session, session.videoID == videoID else { return }
        let seconds = max(0, Int(position.rounded(.down)))

        if !session.atrSent, seconds >= Int(session.urls.atrAfterSeconds), let atrURL = session.urls.atrURL {
            session.atrSent = true
            Task { [api, cpn = session.cpn] in
                do {
                    try await api.pingATR(atrURL, cpn: cpn)
                } catch {
                    self.logger.warning("History ATR ping failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        guard let watchtimeURL = session.urls.watchtimeURL else { return }
        let covered = max(session.reportedSeconds, session.flushingToSeconds)
        guard seconds - covered >= reportIntervalSeconds else { return }
        session.flushingToSeconds = seconds
        Task { [api, cpn = session.cpn, weak session] in
            guard let session else { return }
            do {
                try await api.pingWatchtime(watchtimeURL, cpn: cpn, seconds: seconds, final: false)
                session.reportedSeconds = max(session.reportedSeconds, seconds)
            } catch {
                session.flushingToSeconds = session.reportedSeconds
                self.logger.warning("History watchtime ping failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func onTrackChanged(position: TimeInterval) {
        close(position: position, final: true)
    }

    func onPlaybackFinished(position: TimeInterval) {
        close(position: position, final: true)
    }

    private func close(position: TimeInterval, final: Bool) {
        generation = UUID()
        openingTask?.cancel()
        openingTask = nil
        openingVideoID = nil
        guard let closing = session else { return }
        session = nil
        guard let watchtimeURL = closing.urls.watchtimeURL else { return }
        let seconds = max(0, Int(position.rounded(.down)))
        Task { [api, cpn = closing.cpn] in
            do {
                try await api.pingWatchtime(watchtimeURL, cpn: cpn, seconds: seconds, final: final)
            } catch {
                self.logger.warning("Final history watchtime ping failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func isYouTubeVideoID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
    }

    private static func makeCPN() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
    }
}

struct SilenceInterval: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

struct SilenceDetector {
    let minimumDuration: TimeInterval
    let amplitudeThreshold: Double
    private(set) var silenceStart: TimeInterval?

    init(minimumDuration: TimeInterval = 1, amplitudeThreshold: Double = 1_024.0 / 32_768.0) {
        self.minimumDuration = minimumDuration
        self.amplitudeThreshold = amplitudeThreshold
    }

    mutating func consume(
        peakAmplitude: Double,
        start: TimeInterval,
        duration: TimeInterval
    ) -> SilenceInterval? {
        if peakAmplitude <= amplitudeThreshold {
            if silenceStart == nil { silenceStart = start }
            return nil
        }
        return closeSilence(at: start)
    }

    mutating func finish(at end: TimeInterval) -> SilenceInterval? {
        closeSilence(at: end)
    }

    private mutating func closeSilence(at end: TimeInterval) -> SilenceInterval? {
        guard let start = silenceStart else { return nil }
        silenceStart = nil
        guard end - start >= minimumDuration else { return nil }
        return SilenceInterval(start: start, end: end)
    }
}

enum SilenceAnalyzer {
    static func intervals(for asset: AVAsset) -> AsyncStream<SilenceInterval> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                guard let track = asset.tracks(withMediaType: .audio).first,
                      let reader = try? AVAssetReader(asset: asset) else {
                    continuation.finish()
                    return
                }

                let output = AVAssetReaderTrackOutput(
                    track: track,
                    outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsNonInterleaved: false
                    ]
                )
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else {
                    continuation.finish()
                    return
                }
                reader.add(output)
                guard reader.startReading() else {
                    continuation.finish()
                    return
                }

                var detector = SilenceDetector()
                var lastSampleEnd: TimeInterval = 0

                while !Task.isCancelled, let sampleBuffer = output.copyNextSampleBuffer() {
                    let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                    guard start.isFinite,
                          let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

                    let byteCount = CMBlockBufferGetDataLength(blockBuffer)
                    guard byteCount >= MemoryLayout<Int16>.size else { continue }
                    var dataPointer: UnsafeMutablePointer<Int8>?
                    let status = CMBlockBufferGetDataPointer(
                        blockBuffer,
                        atOffset: 0,
                        lengthAtOffsetOut: nil,
                        totalLengthOut: nil,
                        dataPointerOut: &dataPointer
                    )
                    guard status == kCMBlockBufferNoErr, let dataPointer else { continue }

                    let sampleCount = byteCount / MemoryLayout<Int16>.size
                    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
                        continue
                    }
                    let sampleRate = streamDescription.pointee.mSampleRate
                    let channelCount = max(1, Int(streamDescription.pointee.mChannelsPerFrame))
                    guard sampleRate > 0 else { continue }
                    let frameCount = sampleCount / channelCount
                    let windowFrameCount = max(1, Int(sampleRate * 0.02))

                    dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                        var frameOffset = 0
                        while frameOffset < frameCount {
                            let framesInWindow = min(windowFrameCount, frameCount - frameOffset)
                            let firstSample = frameOffset * channelCount
                            let lastSample = (frameOffset + framesInWindow) * channelCount
                            var peak = 0
                            for index in firstSample..<lastSample {
                                peak = max(peak, abs(Int(samples[index])))
                            }
                            let windowStart = start + Double(frameOffset) / sampleRate
                            let windowDuration = Double(framesInWindow) / sampleRate
                            lastSampleEnd = windowStart + windowDuration
                            if let interval = detector.consume(
                                peakAmplitude: Double(peak) / 32_768,
                                start: windowStart,
                                duration: windowDuration
                            ) {
                                continuation.yield(interval)
                            }
                            frameOffset += framesInWindow
                        }
                    }
                }

                if !Task.isCancelled, let interval = detector.finish(at: lastSampleEnd) {
                    continuation.yield(interval)
                }
                if Task.isCancelled { reader.cancelReading() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum PlaybackRepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one

    var title: String {
        switch self {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }

    var systemImage: String {
        self == .one ? "repeat.1" : "repeat"
    }

    var next: PlaybackRepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// A small cold-start snapshot of the player's queue, matching Android's
/// `LastPlayed` behavior. It deliberately lives outside the portable backup:
/// local paths and the last listening position belong to this Mac only.
final class PlaybackQueueStore {
    struct Snapshot: Equatable {
        let tracks: [Track]
        let index: Int
        let position: TimeInterval
    }

    static let storageKey = "BitChord.playback.lastQueue"
    static let keepBehind = 10
    static let maximumTracks = 60

    private struct StoredQueue: Codable {
        let version: Int
        let tracks: [Track]
        let index: Int
        let position: TimeInterval
    }

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard, key: String = storageKey) {
        self.defaults = defaults
        self.key = key
    }

    func save(tracks: [Track], index: Int, position: TimeInterval) {
        guard !tracks.isEmpty else { return }
        let currentIndex = min(max(index, 0), tracks.count - 1)
        let latestStart = max(0, tracks.count - Self.maximumTracks)
        let start = min(max(currentIndex - Self.keepBehind, 0), latestStart)
        let end = min(tracks.count, start + Self.maximumTracks)
        let window = tracks[start..<end].map { track -> Track in
            var sanitized = track
            if let duration = sanitized.duration, !duration.isFinite || duration <= 0 {
                sanitized.duration = nil
            }
            return sanitized
        }
        let safePosition = position.isFinite ? max(0, position) : 0
        let stored = StoredQueue(
            version: 1,
            tracks: window,
            index: currentIndex - start,
            position: safePosition
        )
        guard let data = try? encoder.encode(stored) else { return }
        defaults.set(data, forKey: key)
    }

    func load() -> Snapshot? {
        guard let data = defaults.data(forKey: key), data.count <= 2_000_000,
              let stored = try? decoder.decode(StoredQueue.self, from: data),
              stored.version == 1, !stored.tracks.isEmpty else { return nil }
        let tracks = Array(stored.tracks.prefix(Self.maximumTracks))
        let index = min(max(stored.index, 0), tracks.count - 1)
        let position = stored.position.isFinite ? max(0, stored.position) : 0
        return Snapshot(tracks: tracks, index: index, position: position)
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    private let logger = Logger(subsystem: "com.bitchord.mac", category: "Playback")
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var lyricsLoading = false
    @Published private(set) var queue: [Track] = []
    @Published private(set) var queueIndex = 0
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var sleepTimerEnd: Date?
    @Published private(set) var stopAfterCurrent = false
    @Published private(set) var streamInfo: AudioStreamInfo?
    @Published private(set) var skipSilenceEnabled = false
    @Published private(set) var skippedSilenceSeconds: TimeInterval = 0
    @Published private(set) var crossfadeSeconds = 0
    @Published private(set) var isTransitioning = false
    @Published private(set) var equalizerActive = false
    @Published private(set) var spatialAudioActive = false
    @Published private(set) var automixEnabled = false
    @Published private(set) var automixStatus: AutomixAnalysisStatus = .off
    @Published private(set) var autoplayEnabled = true
    @Published private(set) var autoplayLoading = false
    @Published private(set) var repeatMode: PlaybackRepeatMode = .off
    @Published private(set) var shuffleEnabled = false
    @Published private(set) var volume: Float

    private let api: any PlaybackStreamResolving
    private let autoplayAPI: (any AutoplayTrackProviding)?
    private let historyTracker: PlaybackHistoryTracker?
    private let listeningRecorder: ListeningRecorder?
    private let scrobbling: ScrobblingManager?
    private let queueStore: PlaybackQueueStore?
    private let volumeDefaults: UserDefaults
    private var queuePersistenceCancellable: AnyCancellable?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var resolvingTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var playbackRequestID = UUID()
    private var activeTrackAliases = Set<String>()
    private var fallbackRequestID: UUID?
    private var currentPlaybackAsset: AVAsset?
    private var authoritativeDuration: TimeInterval?
    private var streamProxy: LocalStreamProxy?
    private var preloadTask: Task<Void, Never>?
    private var audioCacheTask: Task<Void, Never>?
    private var preloadedPlayer: AVPlayer?
    private var preloadedItem: AVPlayerItem?
    private var preloadedAsset: AVAsset?
    private var preloadedTrack: Track?
    private var preloadedSourceTrackID: String?
    private var preloadedQueueIndex: Int?
    private var preloadedStreamInfo: AudioStreamInfo?
    private var preloadedResolvedStream: ResolvedStream?
    private var preloadedDuration: TimeInterval?
    private var preloadedProxy: LocalStreamProxy?
    private var preloadedStatusObservation: NSKeyValueObservation?
    private var preloadedPlayerStatusObservation: NSKeyValueObservation?
    private var preloadedReady = false
    private var transitionTask: Task<Void, Never>?
    private var qualityUpgradeTask: Task<Void, Never>?
    private var silenceAnalysisTask: Task<Void, Never>?
    private var autoplayTask: Task<Void, Never>?
    private var autoplaySeed: String?
    private var avoidRepeatedSuggestions = false
    private var autoplaySessionHistory = Set<String>()
    private var advanceWhenAutoplayArrives = false
    private var repeatAllStash: [Track] = []
    private var repeatAllStashSeed: String?
    private var shuffleOriginalQueue: [Track]?
    private var silenceIntervals: [SilenceInterval] = []
    private var skippedSilenceIntervals: Set<Int64> = []
    private var equalizerSnapshot = EqualizerSnapshot.disabled
    private var equalizerRevision = 0
    private var spatialAudioEnabled = false
    private let automixAnalyzer = AutomixAnalyzer()
    private var currentAutomixAnalysis: AutomixTrackAnalysis?
    private var preloadedAutomixAnalysis: AutomixTrackAnalysis?
    private var currentAutomixTask: Task<Void, Never>?
    private var preloadedAutomixTask: Task<Void, Never>?
    private var currentAutomixRunning = false
    private var preloadedAutomixRunning = false
    private var activeAutomixPlan: AutomixTransitionPlan?
    private var transitionIncomingRate = 1.0
    private var transitionOutgoingGain: Float = 1
    private var transitionIncomingGain: Float = 0
    private var lastAudibleVolume: Float = 1

    private static let volumeKey = "BitChord.playerVolume"

    private struct PreparedHandoff {
        let player: AVPlayer
        let item: AVPlayerItem
        let asset: AVAsset
        let track: Track
        let sourceTrackID: String
        let queueIndex: Int
        let streamInfo: AudioStreamInfo?
        let resolvedStream: ResolvedStream?
        let duration: TimeInterval?
        let streamProxy: LocalStreamProxy?
        let automixAnalysis: AutomixTrackAnalysis?
    }

    init(
        api: any PlaybackStreamResolving,
        autoplayAPI: (any AutoplayTrackProviding)? = nil,
        historyAPI: (any PlaybackHistoryAPI)? = nil,
        listeningRecorder: ListeningRecorder? = nil,
        scrobbling: ScrobblingManager? = nil,
        queueStore: PlaybackQueueStore? = nil,
        volumeDefaults: UserDefaults = .standard
    ) {
        self.api = api
        self.autoplayAPI = autoplayAPI
        self.listeningRecorder = listeningRecorder
        self.scrobbling = scrobbling
        self.queueStore = queueStore
        self.volumeDefaults = volumeDefaults
        let restoredVolume = Self.clampedVolume(
            (volumeDefaults.object(forKey: Self.volumeKey) as? NSNumber)?.doubleValue ?? 1
        )
        volume = restoredVolume
        if let historyAPI {
            historyTracker = PlaybackHistoryTracker(api: historyAPI)
        } else {
            historyTracker = nil
        }
        if restoredVolume > 0.001 { lastAudibleVolume = restoredVolume }
        restoreQueueSnapshot()
        configureRemoteCommands()
        observeQueueForPersistence()
    }

    var onHistoryRegistered: (() -> Void)? {
        get { historyTracker?.onRegisteredPlay }
        set { historyTracker?.onRegisteredPlay = newValue }
    }

    var isMuted: Bool { volume <= 0.001 }

    func setVolume(_ value: Double) {
        let clamped = Self.clampedVolume(value)
        if clamped > 0.001 { lastAudibleVolume = clamped }
        guard volume != clamped else { return }
        volume = clamped
        volumeDefaults.set(Double(clamped), forKey: Self.volumeKey)
        applyMasterVolume()
    }

    func adjustVolume(by delta: Double) {
        setVolume(Double(volume) + delta)
    }

    func toggleMute() {
        setVolume(isMuted ? Double(max(lastAudibleVolume, 0.35)) : 0)
    }

    nonisolated static func clampedVolume(_ value: Double) -> Float {
        guard value.isFinite else { return 1 }
        return Float(min(max(value, 0), 1))
    }

    nonisolated static func outputVolume(master: Float, gain: Float) -> Float {
        min(max(master, 0), 1) * min(max(gain, 0), 1)
    }

    private func applyMasterVolume() {
        player?.volume = Self.outputVolume(
            master: volume,
            gain: isTransitioning ? transitionOutgoingGain : 1
        )
        preloadedPlayer?.volume = Self.outputVolume(
            master: volume,
            gain: isTransitioning ? transitionIncomingGain : 0
        )
    }

    private func applyTransitionVolumes(
        outgoing: AVPlayer,
        incoming: AVPlayer,
        gains: (outgoing: Float, incoming: Float)
    ) {
        transitionOutgoingGain = gains.outgoing
        transitionIncomingGain = gains.incoming
        outgoing.volume = Self.outputVolume(master: volume, gain: gains.outgoing)
        incoming.volume = Self.outputVolume(master: volume, gain: gains.incoming)
    }

    deinit {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        itemStatusObservation?.invalidate()
        timeControlObservation?.invalidate()
        sleepTask?.cancel()
        lyricsTask?.cancel()
        preloadTask?.cancel()
        audioCacheTask?.cancel()
        transitionTask?.cancel()
        qualityUpgradeTask?.cancel()
        preloadedStatusObservation?.invalidate()
        preloadedPlayerStatusObservation?.invalidate()
        preloadedPlayer?.cancelPendingPrerolls()
        preloadedPlayer?.pause()
        preloadedProxy?.stop()
        silenceAnalysisTask?.cancel()
        autoplayTask?.cancel()
        currentAutomixTask?.cancel()
        preloadedAutomixTask?.cancel()
        streamProxy?.stop()
    }

    func play(
        _ track: Track,
        queue: [Track]? = nil,
        at requestedQueueIndex: Int? = nil,
        preservingQueueOrder: Bool = false,
        resumeAt requestedPosition: TimeInterval? = nil
    ) {
        let resumePosition = Self.restoredPosition(requestedPosition, duration: track.duration)
        resolvingTask?.cancel()
        audioCacheTask?.cancel()
        autoplayTask?.cancel()
        autoplayLoading = false
        advanceWhenAutoplayArrives = false
        lyricsTask?.cancel()
        lyricsLoading = false
        qualityUpgradeTask?.cancel()
        cancelTransition(keepPreloaded: false)
        listeningRecorder?.onStopped()
        scrobbling?.playbackStopped()
        if currentTrack != nil { historyTracker?.onTrackChanged(position: progress) }
        playbackRequestID = UUID()
        let requestID = playbackRequestID
        fallbackRequestID = nil
        stopCurrentPlayback()
        errorMessage = nil
        lyrics = nil
        streamInfo = nil
        authoritativeDuration = nil
        skippedSilenceSeconds = 0
        currentTrack = track
        activeTrackAliases = [track.id]
        progress = resumePosition ?? 0
        duration = track.duration ?? 0
        isPlaying = false
        isLoading = true

        if let queue, !queue.isEmpty {
            self.queue = queue
            if let requestedQueueIndex,
               queue.indices.contains(requestedQueueIndex),
               queue[requestedQueueIndex].id == track.id {
                queueIndex = requestedQueueIndex
            } else {
                queueIndex = queue.firstIndex(of: track) ?? 0
            }
        } else {
            self.queue = [track]
            queueIndex = 0
        }

        if shuffleEnabled, !preservingQueueOrder {
            shuffleOriginalQueue = self.queue
            let selected = queueIndex
            self.queue = Self.shuffledStartingQueue(self.queue, selectedIndex: selected)
            queueIndex = 0
        } else if !shuffleEnabled {
            shuffleOriginalQueue = nil
        }

        loadLyrics()
        loadAutoplayForCurrentTrack()

        if let localPath = track.localPath {
            statusMessage = "Opening audio…"
            let localURL = URL(fileURLWithPath: localPath)
            start(
                url: localURL,
                headers: [:],
                for: track,
                requestID: requestID,
                durationHint: track.duration ?? Self.audioFileDuration(at: localURL),
                initialPosition: resumePosition
            )
            resolvingTask = Task { [weak self] in
                let info = await Self.inspectAudioFile(
                    at: localURL,
                    sourceName: track.videoID == nil ? "Local file" : "Downloaded file"
                )
                guard let self, !Task.isCancelled, playbackRequestID == requestID else { return }
                streamInfo = info
            }
            return
        }

        guard track.hasRemotePlaybackSource else {
            failPlayback("This item does not have a playable source.")
            return
        }

        statusMessage = track.isMusicVideo
            ? "Finding catalogue audio…"
            : "Finding the best audio stream…"
        resolvingTask = Task { [weak self, api] in
            guard let self else { return }
            var playbackTrack = track
            do {
                playbackTrack = await api.resolvePlaybackTrack(for: track)
                try Task.checkCancellation()
                guard playbackRequestID == requestID else { return }
                playbackTrack = adoptResolvedPlaybackTrack(playbackTrack, replacing: track)
                statusMessage = "Finding the best audio stream…"
                let stream = try await api.resolveStream(for: playbackTrack)
                try Task.checkCancellation()
                guard playbackRequestID == requestID else { return }
                if stream.url.isFileURL {
                    statusMessage = "Opening cached audio…"
                    let info = await Self.inspectAudioFile(
                        at: stream.url,
                        sourceName: "YouTube Music cache"
                    )
                    try Task.checkCancellation()
                    guard playbackRequestID == requestID else { return }
                    streamInfo = info ?? stream.info
                    start(
                        url: stream.url,
                        headers: [:],
                        for: playbackTrack,
                        requestID: requestID,
                        durationHint: stream.duration ?? playbackTrack.duration ?? Self.audioFileDuration(at: stream.url),
                        initialPosition: resumePosition
                    )
                    return
                }
                statusMessage = "Opening audio stream…"
                let endpoint = try await Self.playbackEndpoint(for: stream)
                try Task.checkCancellation()
                guard playbackRequestID == requestID else {
                    endpoint.proxy?.stop()
                    return
                }
                streamInfo = stream.info
                statusMessage = "Buffering…"
                start(
                    url: endpoint.url,
                    headers: [:],
                    for: playbackTrack,
                    requestID: requestID,
                    streamProxy: endpoint.proxy,
                    durationHint: stream.duration ?? playbackTrack.duration,
                    initialPosition: resumePosition
                )
                scheduleAudioCache(stream, requestID: requestID)
            } catch {
                guard !Task.isCancelled, playbackRequestID == requestID else { return }
                if playbackTrack.catalogSource != nil {
                    failPlayback("Could not prepare this \(playbackTrack.catalogSource?.title ?? "music") stream. Try again.")
                } else if api.isAuthenticated {
                    // The Kotlin player falls through to its extractor when no
                    // device-client URL survives a real media read. Keep that
                    // fallback behind the same visible loading state instead
                    // of presenting a dead-end alert before trying it.
                    prepareCompatibleFallback(for: playbackTrack, requestID: requestID)
                } else {
                    failPlayback("Sign in to YouTube Music to play this track in Lilt.")
                }
            }
        }
    }

    /// Replaces only the active queue slot. Upcoming video rows stay lazy and
    /// resolve when selected, while the playing row, Now Playing metadata,
    /// history, lyrics and AutoPlay all switch to the authoritative catalogue
    /// identity before a byte of audio starts.
    private func adoptResolvedPlaybackTrack(_ resolved: Track, replacing original: Track) -> Track {
        guard resolved != original else { return original }
        activeTrackAliases.insert(original.id)
        var adopted = resolved.mergingBrowseLinks(from: original)
        adopted.fromAutoplay = original.fromAutoplay
        if adopted.videoID != original.videoID { adopted.setVideoID = nil }

        if currentTrack?.id == original.id { currentTrack = adopted }
        if queue.indices.contains(queueIndex), queue[queueIndex].id == original.id {
            queue[queueIndex] = adopted
        }
        duration = adopted.duration ?? original.duration ?? duration

        lyricsTask?.cancel()
        lyrics = nil
        lyricsLoading = false
        queue = queue.enumerated().compactMap { index, candidate in
            index > queueIndex && candidate.isFromAutoplay ? nil : candidate
        }
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayLoading = false
        autoplaySeed = nil
        loadLyrics()
        loadAutoplayForCurrentTrack()
        updateNowPlaying()
        return adopted
    }

    func togglePlayback() {
        guard !isLoading else { return }
        if player == nil, let currentTrack {
            play(
                currentTrack,
                queue: queue,
                at: queueIndex,
                preservingQueueOrder: true,
                resumeAt: progress
            )
            return
        }
        guard let player else { return }
        if isPlaying {
            cancelTransition(keepPreloaded: false)
            player.pause()
            isPlaying = false
            listeningRecorder?.onStopped()
            scrobbling?.playbackPaused()
        } else {
            player.playImmediately(atRate: Float(playbackRate))
            isPlaying = true
            if let currentTrack {
                scrobbling?.playbackStarted(
                    track: currentTrack,
                    duration: duration,
                    position: progress
                )
            }
            scheduleNextPreload()
        }
        updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        guard let nextIndex = automaticNextQueueIndex else {
            if autoplayEnabled, !autoplayLoading {
                autoplaySeed = nil
                loadAutoplayForCurrentTrack()
            }
            if autoplayEnabled, autoplayLoading {
                advanceWhenAutoplayArrives = true
                player?.pause()
                isPlaying = false
                isLoading = true
                statusMessage = "Finding more music…"
                return
            }
            cancelTransition(keepPreloaded: false)
            player?.pause()
            isPlaying = false
            listeningRecorder?.onStopped()
            scrobbling?.playbackStopped()
            return
        }
        if !isTransitioning,
           preloadedReady,
           preloadedQueueIndex == nextIndex {
            historyTracker?.onTrackChanged(position: progress)
            if adoptPreloadedImmediately() { return }
        }
        queueIndex = nextIndex
        play(
            queue[nextIndex],
            queue: queue,
            at: nextIndex,
            preservingQueueOrder: true
        )
    }

    func previous() {
        if progress > 8 {
            seek(to: 0)
            return
        }
        let previousIndex = queueIndex - 1
        guard queue.indices.contains(previousIndex) else {
            seek(to: 0)
            return
        }
        queueIndex = previousIndex
        play(
            queue[previousIndex],
            queue: queue,
            at: previousIndex,
            preservingQueueOrder: true
        )
    }

    func playNext(_ track: Track) {
        playNext([track])
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard currentTrack != nil else {
            play(tracks[0], queue: tracks)
            return
        }
        if queue.isEmpty, let currentTrack { queue = [currentTrack] }
        let insertionIndex = min(queueIndex + 1, queue.count)
        queue.insert(contentsOf: manualQueueEntries(tracks), at: insertionIndex)
        scheduleNextPreload()
    }

    func addToQueue(_ track: Track) {
        addToQueue([track])
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard currentTrack != nil else {
            play(tracks[0], queue: tracks)
            return
        }
        if queue.isEmpty, let currentTrack { queue = [currentTrack] }
        queue.insert(contentsOf: manualQueueEntries(tracks), at: autoplaySectionStart)
        scheduleNextPreload()
    }

    private func manualQueueEntries(_ tracks: [Track]) -> [Track] {
        tracks.map { track in
            var manualTrack = track
            manualTrack.fromAutoplay = nil
            return manualTrack
        }
    }

    func playFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let selectedQueue = queue
        let track = selectedQueue[index]
        play(track, queue: selectedQueue, at: index, preservingQueueOrder: true)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != queueIndex else { return }
        queue.remove(at: index)
        if index < queueIndex { queueIndex -= 1 }
        scheduleNextPreload()
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        guard canMoveQueueItem(from: source, to: destination) else { return }
        let item = queue.remove(at: source)
        queue.insert(item, at: destination)
        scheduleNextPreload()
    }

    func canMoveQueueItem(from source: Int, to destination: Int) -> Bool {
        guard queue.indices.contains(source), queue.indices.contains(destination),
              source != destination, source > queueIndex, destination > queueIndex else { return false }
        let boundary = autoplaySectionStart
        return (source >= boundary) == (destination >= boundary)
    }

    var autoplaySectionStart: Int {
        let afterCurrent = min(max(queueIndex + 1, 0), queue.count)
        return (afterCurrent..<queue.count).first { queue[$0].isFromAutoplay } ?? queue.count
    }

    var hasUpcomingTracks: Bool { queueIndex + 1 < queue.count }

    func clearUpcomingQueue() {
        guard hasUpcomingTracks else { return }
        queue.removeSubrange((queueIndex + 1)..<queue.count)
        autoplaySeed = currentTrack?.videoID
        resetPreloadedPlayback()
    }

    func cycleRepeatMode() {
        setRepeatMode(repeatMode.next)
    }

    func setRepeatMode(_ mode: PlaybackRepeatMode) {
        guard repeatMode != mode else { return }
        let previous = repeatMode
        repeatMode = mode

        if mode == .all {
            stashAutoplayForRepeatAll()
        } else if previous == .all {
            restoreAutoplayAfterRepeatAll()
        }

        if mode == .one {
            resetPreloadedPlayback()
        } else {
            scheduleNextPreload()
        }
        updateNowPlaying()
    }

    func toggleShuffle() {
        setShuffle(!shuffleEnabled)
    }

    func setShuffle(_ enabled: Bool) {
        guard shuffleEnabled != enabled else { return }
        if enabled {
            shuffleOriginalQueue = queue
            let from = min(queueIndex + 1, queue.count)
            let upcoming = Array(queue.dropFirst(from))
            let manual = upcoming.filter { !$0.isFromAutoplay }.shuffled()
            let autoplay = upcoming.filter(\.isFromAutoplay).shuffled()
            queue.replaceSubrange(from..<queue.count, with: manual + autoplay)
            shuffleEnabled = true
        } else {
            let from = min(queueIndex + 1, queue.count)
            let prefix = Array(queue.prefix(from))
            let upcoming = Array(queue.dropFirst(from))
            let restored = Self.restoredUpcomingQueue(
                original: shuffleOriginalQueue ?? [],
                upcoming: upcoming
            )
            queue = prefix + restored
            shuffleOriginalQueue = nil
            shuffleEnabled = false
        }
        scheduleNextPreload()
        updateNowPlaying()
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let selectedIndex = Int.random(in: tracks.indices)
        shuffleEnabled = true
        shuffleOriginalQueue = tracks
        let shuffled = Self.shuffledStartingQueue(tracks, selectedIndex: selectedIndex)
        play(
            shuffled[0],
            queue: shuffled,
            at: 0,
            preservingQueueOrder: true
        )
    }

    func setAutoplay(enabled: Bool, avoidRepeatedSuggestions: Bool) {
        let enabledChanged = autoplayEnabled != enabled
        let historyChanged = self.avoidRepeatedSuggestions != avoidRepeatedSuggestions
        autoplayEnabled = enabled
        self.avoidRepeatedSuggestions = avoidRepeatedSuggestions

        if !enabled {
            let wasWaitingForAutoplay = advanceWhenAutoplayArrives
            autoplayTask?.cancel()
            autoplayTask = nil
            autoplayLoading = false
            advanceWhenAutoplayArrives = false
            if wasWaitingForAutoplay {
                isLoading = false
                statusMessage = nil
            }
            queue = queue.enumerated().compactMap { index, candidate in
                index > queueIndex && candidate.isFromAutoplay ? nil : candidate
            }
            autoplaySeed = nil
            repeatAllStash = []
            repeatAllStashSeed = nil
            scheduleNextPreload()
            return
        }

        if enabledChanged || historyChanged {
            autoplaySeed = nil
            if !avoidRepeatedSuggestions { autoplaySessionHistory.removeAll() }
            loadAutoplayForCurrentTrack()
        }
    }

    private func loadAutoplayForCurrentTrack() {
        guard autoplayEnabled, repeatMode != .all,
              let autoplayAPI, let currentTrack,
              let videoID = currentTrack.videoID else { return }
        let queuedSuggestions = queue.suffix(from: min(queueIndex + 1, queue.count))
            .filter(\.isFromAutoplay).count
        let needed = 10 - queuedSuggestions
        guard needed > 0, autoplaySeed != videoID else { return }

        autoplayTask?.cancel()
        autoplaySeed = videoID
        autoplayLoading = true
        if avoidRepeatedSuggestions {
            autoplaySessionHistory.insert(Self.autoplayIdentity(for: currentTrack))
        }
        let existing = Set(queue.map(Self.autoplayIdentity)).union(
            avoidRepeatedSuggestions ? autoplaySessionHistory : []
        )

        autoplayTask = Task { [weak self, autoplayAPI] in
            do {
                let radio = try await autoplayAPI.autoplayTracks(for: videoID)
                try Task.checkCancellation()
                guard let self, self.autoplayEnabled,
                      self.currentTrack?.videoID == videoID else { return }
                var seen = existing
                var suggestions: [Track] = []
                for candidate in radio where suggestions.count < needed {
                    guard seen.insert(Self.autoplayIdentity(for: candidate)).inserted else { continue }
                    var queued = candidate
                    queued.fromAutoplay = true
                    suggestions.append(queued)
                }
                self.queue.append(contentsOf: suggestions)
                if self.avoidRepeatedSuggestions {
                    self.autoplaySessionHistory.formUnion(suggestions.map(Self.autoplayIdentity))
                }
                self.autoplayLoading = false
                self.autoplayTask = nil
                self.scheduleNextPreload()
                if self.advanceWhenAutoplayArrives {
                    self.advanceWhenAutoplayArrives = false
                    if suggestions.isEmpty {
                        self.isLoading = false
                        self.statusMessage = nil
                    } else {
                        self.next()
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.currentTrack?.videoID == videoID else { return }
                self.logger.warning("AutoPlay load failed: \(error.localizedDescription, privacy: .public)")
                self.autoplayLoading = false
                self.autoplayTask = nil
                self.autoplaySeed = nil
                if self.advanceWhenAutoplayArrives {
                    self.advanceWhenAutoplayArrives = false
                    self.isLoading = false
                    self.statusMessage = nil
                }
            }
        }
    }

    private static func autoplayIdentity(for track: Track) -> String {
        track.videoID.map { "youtube:\($0)" } ?? track.id
    }

    private var automaticNextQueueIndex: Int? {
        let sequential = queueIndex + 1
        if queue.indices.contains(sequential) { return sequential }
        if repeatMode == .all, !queue.isEmpty { return 0 }
        return nil
    }

    private func stashAutoplayForRepeatAll() {
        guard repeatAllStash.isEmpty else { return }
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayLoading = false
        if advanceWhenAutoplayArrives {
            advanceWhenAutoplayArrives = false
            isLoading = false
            statusMessage = nil
        }
        repeatAllStash = queue.enumerated().compactMap { index, track in
            index > queueIndex && track.isFromAutoplay ? track : nil
        }
        repeatAllStashSeed = currentTrack.map(Self.autoplayIdentity)
        queue = queue.enumerated().compactMap { index, track in
            index > queueIndex && track.isFromAutoplay ? nil : track
        }
        resetPreloadedPlayback()
    }

    private func restoreAutoplayAfterRepeatAll() {
        let stashed = repeatAllStash
        let seed = repeatAllStashSeed
        repeatAllStash = []
        repeatAllStashSeed = nil
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayLoading = false
        autoplaySeed = nil

        if autoplayEnabled,
           currentTrack.map(Self.autoplayIdentity) == seed {
            var present = Set(queue.map(Self.autoplayIdentity))
            queue.append(contentsOf: stashed.filter { present.insert(Self.autoplayIdentity(for: $0)).inserted })
        }
        loadAutoplayForCurrentTrack()
    }

    private static func shuffledStartingQueue(_ tracks: [Track], selectedIndex: Int) -> [Track] {
        guard tracks.indices.contains(selectedIndex) else { return tracks }
        let selected = tracks[selectedIndex]
        let remaining = tracks.enumerated().compactMap { index, track in
            index == selectedIndex ? nil : track
        }
        return [selected]
            + remaining.filter { !$0.isFromAutoplay }.shuffled()
            + remaining.filter(\.isFromAutoplay).shuffled()
    }

    private static func restoredUpcomingQueue(original: [Track], upcoming: [Track]) -> [Track] {
        var remaining = upcoming
        var restored: [Track] = []
        for candidate in original {
            guard let index = remaining.firstIndex(where: { sameQueueEntry($0, candidate) }) else { continue }
            restored.append(remaining.remove(at: index))
        }
        restored.append(contentsOf: remaining)
        return restored.filter { !$0.isFromAutoplay } + restored.filter(\.isFromAutoplay)
    }

    private static func sameQueueEntry(_ lhs: Track, _ rhs: Track) -> Bool {
        lhs == rhs
    }

    func setPlaybackRate(_ value: Double) {
        let rate = PlaybackSettings.clampedPlaybackSpeed(value)
        playbackRate = rate
        player?.defaultRate = Float(rate)
        if isPlaying { player?.rate = Float(rate) }
        preloadedPlayer?.defaultRate = Float(rate)
        if isTransitioning { preloadedPlayer?.rate = Float(rate * transitionIncomingRate) }
        updateNowPlaying()
    }

    func setSkipSilence(_ enabled: Bool) {
        guard skipSilenceEnabled != enabled else { return }
        skipSilenceEnabled = enabled
        if enabled, let currentPlaybackAsset {
            startSilenceAnalysis(for: currentPlaybackAsset, requestID: playbackRequestID)
        } else {
            silenceAnalysisTask?.cancel()
            silenceAnalysisTask = nil
            silenceIntervals = []
            skippedSilenceIntervals = []
        }
    }

    func setCrossfade(seconds: Int) {
        let clamped = min(max(seconds, 0), 12)
        guard crossfadeSeconds != clamped else { return }
        crossfadeSeconds = clamped
        if clamped == 0, isTransitioning {
            cancelTransition(keepPreloaded: true)
        }
        scheduleNextPreload()
    }

    func setAutomix(enabled: Bool) {
        guard automixEnabled != enabled else { return }
        automixEnabled = enabled
        if enabled {
            if let asset = currentPlaybackAsset, let track = currentTrack {
                scheduleCurrentAutomixAnalysis(asset: asset, track: track, duration: authoritativeDuration ?? duration)
            }
            if let asset = preloadedAsset, let track = preloadedTrack {
                schedulePreloadedAutomixAnalysis(asset: asset, track: track, duration: preloadedDuration ?? track.duration)
            }
        } else {
            currentAutomixTask?.cancel()
            preloadedAutomixTask?.cancel()
            currentAutomixRunning = false
            preloadedAutomixRunning = false
            automixStatus = .off
            if isTransitioning, activeAutomixPlan != nil {
                cancelTransition(keepPreloaded: true)
            }
        }
        scheduleNextPreload()
    }

    func setEqualizer(_ snapshot: EqualizerSnapshot) {
        guard equalizerSnapshot != snapshot else { return }
        equalizerSnapshot = snapshot
        equalizerRevision += 1
        equalizerActive = false
        player?.currentItem?.audioMix = nil
        preloadedItem?.audioMix = nil
        if let item = player?.currentItem { configureAudioEffects(for: item) }
        if let item = preloadedItem { configureAudioEffects(for: item) }
    }

    func setSpatialAudio(enabled: Bool) {
        guard spatialAudioEnabled != enabled else { return }
        spatialAudioEnabled = enabled
        equalizerRevision += 1
        spatialAudioActive = false
        player?.currentItem?.audioMix = nil
        preloadedItem?.audioMix = nil
        if let item = player?.currentItem { configureAudioEffects(for: item, spatialAudioEnabled: enabled) }
        if let item = preloadedItem { configureAudioEffects(for: item, spatialAudioEnabled: enabled) }
    }

    func scheduleSleepTimer(after interval: TimeInterval) {
        guard interval > 0 else { return }
        sleepTask?.cancel()
        stopAfterCurrent = false
        sleepTimerEnd = Date().addingTimeInterval(interval)
        sleepTask = Task { [weak self] in
            let nanoseconds = UInt64(min(interval, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            cancelTransition(keepPreloaded: false)
            player?.pause()
            isPlaying = false
            listeningRecorder?.onStopped()
            scrobbling?.playbackStopped()
            sleepTimerEnd = nil
            sleepTask = nil
            updateNowPlaying()
        }
    }

    func setStopAfterCurrent() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEnd = nil
        cancelTransition(keepPreloaded: false)
        stopAfterCurrent = true
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerEnd = nil
        stopAfterCurrent = false
    }

    func handleTrackEnded() {
        if isTransitioning {
            finishCrossfade()
            return
        }
        listeningRecorder?.onStopped()
        scrobbling?.playbackStopped()
        historyTracker?.onPlaybackFinished(position: max(progress, duration))
        if stopAfterCurrent {
            stopAfterCurrent = false
            resetPreloadedPlayback()
            player?.pause()
            isPlaying = false
            progress = duration
            updateNowPlaying()
        } else if repeatMode == .one, let currentTrack {
            play(
                currentTrack,
                queue: queue,
                at: queueIndex,
                preservingQueueOrder: true
            )
        } else if adoptPreloadedImmediately() {
            return
        } else {
            next()
        }
    }

    func seek(to value: TimeInterval) {
        guard let player, !isLoading else { return }
        cancelTransition(keepPreloaded: false)
        let clampedValue = min(max(0, value), duration > 0 ? duration : .greatestFiniteMagnitude)
        let target = CMTime(seconds: clampedValue, preferredTimescale: 600)
        player.seek(to: target)
        progress = clampedValue
        scheduleNextPreload()
        updateNowPlaying()
    }

    /// Flushes the cold-start snapshot for app deactivation/termination and
    /// gives tests a deterministic persistence boundary.
    func savePlaybackState() {
        persistQueueSnapshot()
    }

    func loadLyrics() {
        guard let track = currentTrack, !lyricsLoading else { return }
        let requestID = playbackRequestID
        lyricsLoading = true
        lyricsTask = Task { [weak self, api] in
            guard let self else { return }
            let localURL = track.localPath.map(URL.init(fileURLWithPath:))
            var result: Lyrics?
            if let localURL {
                result = await EmbeddedLyricsStore.load(from: localURL)
            }
            if result == nil {
                result = try? await api.lyrics(for: track)
                if let localURL, let result {
                    _ = await EmbeddedLyricsStore.embed(result, in: localURL)
                }
            }
            guard !Task.isCancelled,
                  playbackRequestID == requestID,
                  currentTrack?.id == track.id else { return }
            lyrics = result
            lyricsLoading = false
        }
    }

    func reloadLyrics() {
        lyricsTask?.cancel()
        lyricsTask = nil
        lyricsLoading = false
        lyrics = nil
        loadLyrics()
    }

    func retryCurrent() {
        guard let currentTrack else { return }
        play(currentTrack, queue: queue)
    }

    func isLoading(_ track: Track) -> Bool {
        isLoading && isCurrent(track)
    }

    func isCurrent(_ track: Track) -> Bool {
        guard let currentTrack else { return false }
        if currentTrack.id == track.id || activeTrackAliases.contains(track.id) { return true }
        guard let currentVideoID = currentTrack.videoID,
              let candidateVideoID = track.videoID else { return false }
        return currentVideoID == candidateVideoID
    }

    /// Replaces a lossy stream with a module's better copy without restarting
    /// the song. The candidate is buffered silently at the current position,
    /// aligned once more immediately before handoff, then blended over half a
    /// second so a slow Hi-Res module never delays the first note.
    func upgradeCurrentTrack(_ track: Track, to stream: ResolvedStream) {
        guard currentTrack?.id == track.id,
              track.localPath == nil,
              isPlaying,
              !isLoading,
              !isTransitioning,
              stream.info?.isMeaningfullyBetter(than: streamInfo) == true,
              duration <= 0 || duration - progress > 8 else { return }

        qualityUpgradeTask?.cancel()
        let requestID = playbackRequestID
        qualityUpgradeTask = Task { [weak self] in
            guard let self else { return }
            var upgradeProxy: LocalStreamProxy?
            do {
                let endpoint = try await Self.playbackEndpoint(for: stream)
                upgradeProxy = endpoint.proxy
                try Task.checkCancellation()
                guard playbackRequestID == requestID, currentTrack?.id == track.id else {
                    endpoint.proxy?.stop()
                    return
                }

                let asset = AVURLAsset(url: endpoint.url)
                let playable = try await asset.load(.isPlayable)
                guard playable else { throw YouTubeMusicAPIError.noPlayableStream }
                let item = AVPlayerItem(asset: asset)
                configureAudioEffects(for: item)
                item.preferredForwardBufferDuration = 8
                let incoming = AVPlayer(playerItem: item)
                incoming.defaultRate = Float(playbackRate)
                incoming.volume = 0

                let firstTarget = CMTime(seconds: progress, preferredTimescale: 600)
                await withCheckedContinuation { continuation in
                    incoming.seek(to: firstTarget, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        continuation.resume()
                    }
                }
                incoming.playImmediately(atRate: Float(playbackRate))
                let readyDeadline = Date().addingTimeInterval(6)
                while incoming.timeControlStatus != .playing && item.status != .failed {
                    try Task.checkCancellation()
                    guard Date() < readyDeadline else { throw YouTubeMusicAPIError.noPlayableStream }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard item.status != .failed else { throw YouTubeMusicAPIError.noPlayableStream }

                incoming.pause()
                let alignedTarget = CMTime(seconds: progress, preferredTimescale: 600)
                await withCheckedContinuation { continuation in
                    incoming.seek(to: alignedTarget, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        continuation.resume()
                    }
                }
                try Task.checkCancellation()
                guard playbackRequestID == requestID,
                      currentTrack?.id == track.id,
                      let outgoing = player,
                      isPlaying else {
                    endpoint.proxy?.stop()
                    return
                }

                resetPreloadedPlayback()
                incoming.playImmediately(atRate: Float(playbackRate))
                let fadeDuration = 0.5
                let startedAt = Date()
                while !Task.isCancelled {
                    guard playbackRequestID == requestID, player === outgoing else {
                        incoming.pause()
                        endpoint.proxy?.stop()
                        return
                    }
                    let fraction = Date().timeIntervalSince(startedAt) / fadeDuration
                    let gains = CrossfadeCurve.gains(at: fraction)
                    outgoing.volume = Self.outputVolume(master: volume, gain: gains.outgoing)
                    incoming.volume = Self.outputVolume(master: volume, gain: gains.incoming)
                    if fraction >= 1 { break }
                    try await Task.sleep(for: .milliseconds(25))
                }

                outgoing.pause()
                streamInfo = stream.info
                logger.info("Quality upgrade handoff: \(track.title, privacy: .public) → \(stream.info?.shortDescription ?? "module stream", privacy: .public)")
                activate(
                    incoming,
                    item: item,
                    asset: asset,
                    track: track,
                    requestID: requestID,
                    streamProxy: endpoint.proxy,
                    startPlayback: false,
                    durationHint: stream.duration ?? authoritativeDuration ?? track.duration
                )
                scheduleAudioCache(stream, requestID: requestID)
                upgradeProxy = nil
            } catch {
                upgradeProxy?.stop()
                guard !Task.isCancelled else { return }
                logger.debug("Quality upgrade skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func start(
        url: URL,
        headers: [String: String],
        for track: Track,
        requestID: UUID,
        streamProxy: LocalStreamProxy? = nil,
        durationHint: TimeInterval? = nil,
        initialPosition: TimeInterval? = nil
    ) {
        guard playbackRequestID == requestID else { return }
        guard FileManager.default.fileExists(atPath: url.path) || track.localPath == nil else {
            failPlayback("The imported audio file is no longer available.")
            return
        }

        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
            if let userAgent = headers["User-Agent"] {
                options[AVURLAssetHTTPUserAgentKey] = userAgent
            }
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        let nextPlayer = AVPlayer(playerItem: item)
        activate(
            nextPlayer,
            item: item,
            asset: asset,
            track: track,
            requestID: requestID,
            streamProxy: streamProxy,
            startPlayback: true,
            durationHint: durationHint,
            initialPosition: initialPosition
        )
    }

    private func activate(
        _ nextPlayer: AVPlayer,
        item: AVPlayerItem,
        asset: AVAsset,
        track: Track,
        requestID: UUID,
        streamProxy: LocalStreamProxy?,
        startPlayback: Bool,
        durationHint: TimeInterval?,
        initialPosition: TimeInterval? = nil
    ) {
        guard playbackRequestID == requestID else {
            nextPlayer.pause()
            streamProxy?.stop()
            return
        }
        removeObservers()
        self.streamProxy = streamProxy
        currentPlaybackAsset = asset
        authoritativeDuration = Self.validDuration(durationHint) ?? Self.validDuration(track.duration)
        item.audioTimePitchAlgorithm = .spectral
        nextPlayer.defaultRate = Float(playbackRate)
        player = nextPlayer
        configureAudioEffects(for: item)
        let currentSeconds = nextPlayer.currentTime().seconds
        duration = authoritativeDuration ?? 0
        let startingPosition = Self.restoredPosition(initialPosition, duration: duration)
        if let startingPosition {
            nextPlayer.seek(
                to: CMTime(seconds: startingPosition, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            progress = startingPosition
        } else {
            progress = currentSeconds.isFinite ? max(0, currentSeconds) : 0
        }
        statusMessage = startPlayback ? "Buffering…" : nil
        isLoading = startPlayback
        isPlaying = !startPlayback && nextPlayer.timeControlStatus == .playing
        nextPlayer.volume = volume

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak nextPlayer] item, _ in
            Task { @MainActor [weak self, weak nextPlayer] in
                guard let self, let nextPlayer, self.player === nextPlayer,
                      self.playbackRequestID == requestID else { return }
                if item.status == .failed {
                    self.logger.error("AVPlayer item failed: \(item.error?.localizedDescription ?? "unknown", privacy: .public)")
                    if track.localPath == nil,
                       track.catalogSource == nil,
                       self.fallbackRequestID != requestID {
                        self.api.invalidateResolvedStream(for: track)
                        self.prepareCompatibleFallback(for: track, requestID: requestID)
                    } else {
                        let source = track.catalogSource?.title ?? "YouTube Music"
                        self.failPlayback("Could not play this \(source) stream. Try again.")
                    }
                }
            }
        }
        timeControlObservation = nextPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak nextPlayer] player, _ in
            Task { @MainActor [weak self, weak nextPlayer] in
                guard let self, let nextPlayer, self.player === nextPlayer,
                      self.playbackRequestID == requestID else { return }
                switch player.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate:
                    self.isLoading = true
                    self.isPlaying = false
                    self.statusMessage = "Buffering…"
                    self.listeningRecorder?.onStopped()
                    self.scrobbling?.playbackPaused()
                case .playing:
                    self.isLoading = false
                    self.isPlaying = true
                    self.statusMessage = nil
                    if let videoID = track.videoID { self.historyTracker?.onPlaying(videoID: videoID) }
                    self.scrobbling?.playbackStarted(
                        track: track,
                        duration: self.duration,
                        position: self.progress
                    )
                case .paused:
                    self.listeningRecorder?.onStopped()
                    self.scrobbling?.playbackPaused()
                    if item.status == .readyToPlay {
                        self.isLoading = false
                        self.isPlaying = false
                        self.statusMessage = nil
                    }
                @unknown default:
                    break
                }
                self.updateNowPlaying()
            }
        }

        timeObserver = nextPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                progress = max(0, time.seconds.isFinite ? time.seconds : 0)
                let itemDuration = nextPlayer.currentItem?.duration.seconds
                duration = Self.effectiveDuration(
                    authoritative: authoritativeDuration,
                    playerReported: itemDuration
                )
                if Self.reachedAuthoritativeEnd(
                    progress: progress,
                    authoritativeDuration: authoritativeDuration,
                    isPlaying: isPlaying
                ) {
                    progress = duration
                    handleTrackEnded()
                    return
                }
                considerAutomaticTransition()
                if let videoID = currentTrack?.videoID, isPlaying {
                    historyTracker?.onProgress(videoID: videoID, position: progress)
                }
                if let currentTrack, isPlaying {
                    listeningRecorder?.onSample(track: currentTrack, duration: duration)
                    scrobbling?.playbackSample(
                        track: currentTrack,
                        duration: duration,
                        position: progress
                    )
                }
                skipCurrentSilenceIfNeeded(using: nextPlayer)
                updateNowPlaying()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTrackEnded() }
        }

        if startPlayback {
            nextPlayer.playImmediately(atRate: Float(playbackRate))
        }
        if skipSilenceEnabled {
            startSilenceAnalysis(for: asset, requestID: requestID)
        }
        if automixEnabled {
            scheduleCurrentAutomixAnalysis(
                asset: asset,
                track: track,
                duration: authoritativeDuration ?? duration
            )
        }
        scheduleNextPreload()
        updateNowPlaying()
    }

    private func startSilenceAnalysis(for asset: AVAsset, requestID: UUID) {
        silenceAnalysisTask?.cancel()
        silenceIntervals = []
        skippedSilenceIntervals = []
        silenceAnalysisTask = Task { [weak self] in
            for await interval in SilenceAnalyzer.intervals(for: asset) {
                guard let self, !Task.isCancelled,
                      playbackRequestID == requestID,
                      skipSilenceEnabled else { return }
                silenceIntervals.append(interval)
            }
        }
    }

    private func skipCurrentSilenceIfNeeded(using player: AVPlayer) {
        guard skipSilenceEnabled, isPlaying else { return }
        let edgePadding: TimeInterval = 0.08
        guard let interval = silenceIntervals.first(where: {
            progress >= $0.start + edgePadding && progress < $0.end - edgePadding
        }) else { return }
        let key = Int64((interval.start * 1_000).rounded())
        guard !skippedSilenceIntervals.contains(key) else { return }
        let target = interval.end - edgePadding
        guard target - progress >= 0.2 else { return }
        skippedSilenceIntervals.insert(key)
        skippedSilenceSeconds += target - progress
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        progress = target
    }

    private func scheduleNextPreload() {
        guard repeatMode != .one,
              self.player != nil,
              let nextIndex = automaticNextQueueIndex else {
            resetPreloadedPlayback()
            return
        }

        let track = queue[nextIndex]
        if preloadedTrack?.id == track.id,
           preloadedQueueIndex == nextIndex,
           preloadedPlayer != nil {
            return
        }

        resetPreloadedPlayback()
        let generation = playbackRequestID
        preloadTask = Task { [weak self, api] in
            guard let self else { return }
            var proxy: LocalStreamProxy?
            var playbackTrack = track
            do {
                let asset: AVURLAsset
                var info: AudioStreamInfo?
                var resolvedStream: ResolvedStream?
                var durationHint = track.duration
                if let localPath = track.localPath {
                    guard FileManager.default.fileExists(atPath: localPath) else { return }
                    let localURL = URL(fileURLWithPath: localPath)
                    asset = AVURLAsset(url: localURL)
                    durationHint = durationHint ?? Self.audioFileDuration(at: localURL)
                    info = await Self.inspectAudioFile(
                        at: localURL,
                        sourceName: track.videoID == nil ? "Local file" : "Downloaded file"
                    )
                } else {
                    let resolved = await api.resolvePlaybackTrack(for: track)
                    try Task.checkCancellation()
                    guard playbackRequestID == generation,
                          queue.indices.contains(nextIndex),
                          queue[nextIndex].id == track.id else { return }
                    if resolved != track {
                        var adopted = resolved.mergingBrowseLinks(from: track)
                        adopted.fromAutoplay = track.fromAutoplay
                        if adopted.videoID != track.videoID { adopted.setVideoID = nil }
                        playbackTrack = adopted
                        queue[nextIndex] = adopted
                        durationHint = adopted.duration ?? durationHint
                    }
                    let stream = try await api.resolveStream(for: playbackTrack)
                    try Task.checkCancellation()
                    if stream.url.isFileURL {
                        asset = AVURLAsset(url: stream.url)
                        durationHint = stream.duration ?? durationHint ?? Self.audioFileDuration(at: stream.url)
                        info = await Self.inspectAudioFile(
                            at: stream.url,
                            sourceName: "YouTube Music cache"
                        ) ?? stream.info
                    } else {
                        resolvedStream = stream
                        let endpoint = try await Self.playbackEndpoint(for: stream)
                        proxy = endpoint.proxy
                        try Task.checkCancellation()
                        asset = AVURLAsset(url: endpoint.url)
                        info = stream.info
                        durationHint = stream.duration ?? durationHint
                    }
                }

                try Task.checkCancellation()
                guard playbackRequestID == generation,
                      queue.indices.contains(nextIndex),
                      queue[nextIndex].id == playbackTrack.id else {
                    proxy?.stop()
                    return
                }

                let item = AVPlayerItem(asset: asset)
                item.audioTimePitchAlgorithm = .spectral
                item.preferredForwardBufferDuration = max(16, TimeInterval(max(crossfadeSeconds, 12) + 4))
                let preparedPlayer = AVPlayer(playerItem: item)
                preparedPlayer.defaultRate = Float(playbackRate)
                preparedPlayer.volume = 0
                installPreloaded(
                    player: preparedPlayer,
                    item: item,
                    asset: asset,
                    track: playbackTrack,
                    sourceTrackID: track.id,
                    queueIndex: nextIndex,
                    info: info,
                    resolvedStream: resolvedStream,
                    duration: durationHint,
                    proxy: proxy,
                    generation: generation
                )
            } catch {
                proxy?.stop()
                guard !Task.isCancelled else { return }
                logger.debug("Could not preload next track: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func effectiveDuration(
        authoritative: TimeInterval?,
        playerReported: TimeInterval?
    ) -> TimeInterval {
        validDuration(authoritative) ?? validDuration(playerReported) ?? 0
    }

    nonisolated static func reachedAuthoritativeEnd(
        progress: TimeInterval,
        authoritativeDuration: TimeInterval?,
        isPlaying: Bool
    ) -> Bool {
        guard isPlaying, progress.isFinite,
              let duration = validDuration(authoritativeDuration) else { return false }
        return progress >= duration - 0.05
    }

    nonisolated static func audioFileDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return nil }
        return validDuration(Double(file.length) / file.processingFormat.sampleRate)
    }

    nonisolated private static func validDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    nonisolated static func inspectAudioFile(
        at url: URL,
        sourceName: String = "Local file"
    ) async -> AudioStreamInfo? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return nil
        }

        let measuredRate = try? await track.load(.estimatedDataRate)
        let bitrate = measuredRate.flatMap { value in
            value > 0 ? Int((Double(value) / 1_000).rounded()) : nil
        }
        let bitDepth = basic.mBitsPerChannel > 0 ? Int(basic.mBitsPerChannel) : nil
        let sampleRate = basic.mSampleRate > 0 ? Int(basic.mSampleRate.rounded()) : nil
        let channels = basic.mChannelsPerFrame > 0 ? Int(basic.mChannelsPerFrame) : nil

        return AudioStreamInfo(
            requestedQuality: .high,
            bitrateKbps: bitrate,
            codec: codecName(for: basic.mFormatID),
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth,
            sourceName: sourceName
        )
    }

    nonisolated private static func codecName(for formatID: AudioFormatID) -> String? {
        switch formatID {
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatLinearPCM: return "PCM"
        default:
            let bytes: [UInt8] = [
                UInt8((formatID >> 24) & 0xff),
                UInt8((formatID >> 16) & 0xff),
                UInt8((formatID >> 8) & 0xff),
                UInt8(formatID & 0xff)
            ]
            guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
            let label = String(bytes: bytes, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return label?.isEmpty == false ? label?.uppercased() : nil
        }
    }

    private static func playbackEndpoint(
        for stream: ResolvedStream
    ) async throws -> (url: URL, proxy: LocalStreamProxy?) {
        guard stream.requiresLocalPlaybackProxy else {
            return (stream.url, nil)
        }
        let proxy = try LocalStreamProxy(upstreamURL: stream.url, headers: stream.headers)
        do {
            return (try await proxy.start(), proxy)
        } catch {
            proxy.stop()
            throw error
        }
    }

    private func installPreloaded(
        player preparedPlayer: AVPlayer,
        item: AVPlayerItem,
        asset: AVAsset,
        track: Track,
        sourceTrackID: String,
        queueIndex: Int,
        info: AudioStreamInfo?,
        resolvedStream: ResolvedStream?,
        duration: TimeInterval?,
        proxy: LocalStreamProxy?,
        generation: UUID
    ) {
        guard playbackRequestID == generation else {
            preparedPlayer.pause()
            proxy?.stop()
            return
        }
        preloadedPlayer = preparedPlayer
        preloadedItem = item
        preloadedAsset = asset
        preloadedTrack = track
        preloadedSourceTrackID = sourceTrackID
        preloadedQueueIndex = queueIndex
        preloadedStreamInfo = info
        preloadedResolvedStream = resolvedStream
        preloadedDuration = Self.validDuration(duration)
        preloadedProxy = proxy
        preloadedReady = false
        preloadedAutomixAnalysis = nil
        configureAudioEffects(for: item)
        if automixEnabled {
            schedulePreloadedAutomixAnalysis(
                asset: asset,
                track: track,
                duration: preloadedDuration ?? track.duration
            )
        }

        preloadedStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak preparedPlayer] item, _ in
            Task { @MainActor [weak self, weak preparedPlayer] in
                guard let self, let preparedPlayer, preloadedPlayer === preparedPlayer,
                      playbackRequestID == generation else { return }
                if item.status == .failed {
                    logger.debug("Preloaded track was rejected by AVPlayer")
                    resetPreloadedPlayback()
                }
            }
        }
        preloadedPlayerStatusObservation = preparedPlayer.observe(\.status, options: [.initial, .new]) { [weak self, weak preparedPlayer] player, _ in
            Task { @MainActor [weak self, weak preparedPlayer] in
                guard let self, let preparedPlayer, preloadedPlayer === preparedPlayer,
                      playbackRequestID == generation else { return }
                switch player.status {
                case .readyToPlay:
                    guard !preloadedReady else { return }
                    preparedPlayer.preroll(atRate: Float(playbackRate)) { [weak self, weak preparedPlayer] ready in
                        Task { @MainActor [weak self, weak preparedPlayer] in
                            guard let self, let preparedPlayer, preloadedPlayer === preparedPlayer,
                                  playbackRequestID == generation else { return }
                            if ready {
                                logger.info("Next track preroll complete: \(track.title, privacy: .public)")
                                preloadedReady = true
                                refreshAutomixStatus()
                            }
                        }
                    }
                case .failed:
                    logger.debug("Standby AVPlayer failed before preroll")
                    resetPreloadedPlayback()
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func scheduleCurrentAutomixAnalysis(
        asset: AVAsset,
        track: Track,
        duration: TimeInterval?
    ) {
        guard automixEnabled else { return }
        if currentAutomixAnalysis?.trackID == track.id {
            refreshAutomixStatus()
            return
        }
        currentAutomixTask?.cancel()
        currentAutomixAnalysis = nil
        currentAutomixRunning = true
        refreshAutomixStatus()
        let requestID = playbackRequestID
        currentAutomixTask = Task { [weak self, automixAnalyzer = self.automixAnalyzer] in
            let analysis = await automixAnalyzer.analysis(
                for: track.id,
                asset: asset,
                durationHint: duration
            )
            guard let self, !Task.isCancelled,
                  playbackRequestID == requestID,
                  currentTrack?.id == track.id else { return }
            currentAutomixRunning = false
            currentAutomixAnalysis = analysis
            if let analysis {
                logger.info("Automix analyzed current track at \(analysis.bpm, format: .fixed(precision: 1)) BPM")
            }
            refreshAutomixStatus()
        }
    }

    private func schedulePreloadedAutomixAnalysis(
        asset: AVAsset,
        track: Track,
        duration: TimeInterval?
    ) {
        guard automixEnabled else { return }
        if preloadedAutomixAnalysis?.trackID == track.id {
            refreshAutomixStatus()
            return
        }
        preloadedAutomixTask?.cancel()
        preloadedAutomixAnalysis = nil
        preloadedAutomixRunning = true
        refreshAutomixStatus()
        let requestID = playbackRequestID
        preloadedAutomixTask = Task { [weak self, automixAnalyzer = self.automixAnalyzer] in
            let analysis = await automixAnalyzer.analysis(
                for: track.id,
                asset: asset,
                durationHint: duration
            )
            guard let self, !Task.isCancelled,
                  playbackRequestID == requestID,
                  preloadedTrack?.id == track.id else { return }
            preloadedAutomixRunning = false
            preloadedAutomixAnalysis = analysis
            if let analysis {
                logger.info("Automix analyzed next track at \(analysis.bpm, format: .fixed(precision: 1)) BPM")
            }
            refreshAutomixStatus()
        }
    }

    private func refreshAutomixStatus() {
        guard automixEnabled else {
            automixStatus = .off
            return
        }
        if let activeAutomixPlan, isTransitioning {
            automixStatus = .transitioning(activeAutomixPlan.style.title)
        } else if let currentAutomixAnalysis, currentAutomixAnalysis.isUsable,
                  let preloadedAutomixAnalysis, preloadedAutomixAnalysis.isUsable {
            automixStatus = .ready(bpm: Int(preloadedAutomixAnalysis.bpm.rounded()))
        } else if currentAutomixRunning || preloadedAutomixRunning {
            automixStatus = .analyzing
        } else if currentTrack == nil || preloadedTrack == nil {
            automixStatus = .waiting
        } else {
            automixStatus = .fallback
        }
    }

    private func considerAutomaticTransition() {
        guard !stopAfterCurrent,
              repeatMode != .one,
              isPlaying,
              !isLoading,
              !isTransitioning,
              preloadedReady,
              preloadedQueueIndex == automaticNextQueueIndex,
              let incomingTrack = preloadedTrack else { return }

        if automixEnabled, let outgoingTrack = currentTrack {
            let fallbackSeconds = crossfadeSeconds > 0 ? TimeInterval(crossfadeSeconds) : 6
            guard let plan = AutomixPlanner.plan(
                outgoing: currentAutomixAnalysis,
                incoming: preloadedAutomixAnalysis,
                outgoingTrack: outgoingTrack,
                incomingTrack: incomingTrack,
                duration: duration,
                standardFade: fallbackSeconds
            ) else { return }
            guard progress >= plan.transitionStart,
                  progress < plan.transitionEnd,
                  plan.transitionEnd - progress > 0.05 else { return }
            beginAutomix(plan)
            return
        }

        guard crossfadeSeconds > 0 else { return }
        let configured = CrossfadeCurve.duration(
            configuredSeconds: crossfadeSeconds,
            outgoingDuration: duration,
            incomingDuration: incomingTrack.duration
        )
        let remaining = duration - progress
        guard configured > 0, remaining > 0, remaining <= configured else { return }
        beginCrossfade(duration: min(configured, max(remaining, 0.15)))
    }

    private func beginAutomix(_ plan: AutomixTransitionPlan) {
        guard !isTransitioning,
              preloadedReady,
              let outgoing = player,
              let incoming = preloadedPlayer else { return }

        isTransitioning = true
        activeAutomixPlan = plan
        transitionIncomingRate = plan.incomingPlaybackRate
        transitionOutgoingGain = 1
        transitionIncomingGain = 0
        incoming.pause()
        incoming.volume = 0
        refreshAutomixStatus()
        logger.info(
            "Automix armed: \(plan.style.title, privacy: .public), cue \(plan.incomingCueTime, format: .fixed(precision: 2))s, rate \(plan.incomingPlaybackRate, format: .fixed(precision: 4))"
        )

        transitionTask?.cancel()
        transitionTask = Task { [weak self, weak outgoing, weak incoming] in
            guard let self, let outgoing, let incoming else { return }
            let currentOutgoingSeconds = outgoing.currentTime().seconds
            let outgoingPosition = currentOutgoingSeconds.isFinite ? currentOutgoingSeconds : progress
            let effectiveCue = plan.incomingCue(at: outgoingPosition)
            let cue = CMTime(seconds: effectiveCue, preferredTimescale: 600)
            let seeked = await withCheckedContinuation { continuation in
                incoming.seek(to: cue, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    continuation.resume(returning: finished)
                }
            }
            guard seeked, !Task.isCancelled,
                  isTransitioning,
                  player === outgoing,
                  preloadedPlayer === incoming,
                  isPlaying else {
                cancelTransition(keepPreloaded: false)
                return
            }

            let effectiveIncomingRate = playbackRate * plan.incomingPlaybackRate
            incoming.defaultRate = Float(effectiveIncomingRate)
            incoming.playImmediately(atRate: Float(effectiveIncomingRate))
            let remainingTrackTime = max(0.15, plan.transitionEnd - progress)
            let wallDuration = max(0.15, remainingTrackTime / max(playbackRate, 0.5))
            let startedAt = Date()

            while !Task.isCancelled {
                guard isTransitioning,
                      player === outgoing,
                      preloadedPlayer === incoming,
                      isPlaying else {
                    cancelTransition(keepPreloaded: false)
                    return
                }
                let fraction = Date().timeIntervalSince(startedAt) / wallDuration
                let gains = CrossfadeCurve.gains(at: fraction)
                applyTransitionVolumes(outgoing: outgoing, incoming: incoming, gains: gains)
                if fraction >= 1 {
                    finishCrossfade()
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    private func beginCrossfade(duration fadeDuration: TimeInterval) {
        guard !isTransitioning,
              preloadedReady,
              let outgoing = player,
              let incoming = preloadedPlayer else { return }

        isTransitioning = true
        activeAutomixPlan = nil
        transitionIncomingRate = 1
        transitionOutgoingGain = 1
        transitionIncomingGain = 0
        incoming.volume = 0
        incoming.playImmediately(atRate: Float(playbackRate))
        logger.info("Crossfade started: \(fadeDuration, format: .fixed(precision: 2))s")
        let startedAt = Date()

        transitionTask?.cancel()
        transitionTask = Task { [weak self, weak outgoing, weak incoming] in
            guard let self, let outgoing, let incoming else { return }
            while !Task.isCancelled {
                guard isTransitioning,
                      player === outgoing,
                      preloadedPlayer === incoming,
                      isPlaying else {
                    cancelTransition(keepPreloaded: false)
                    return
                }
                let fraction = Date().timeIntervalSince(startedAt) / fadeDuration
                let gains = CrossfadeCurve.gains(at: fraction)
                applyTransitionVolumes(outgoing: outgoing, incoming: incoming, gains: gains)
                if fraction >= 1 {
                    finishCrossfade()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func finishCrossfade() {
        guard isTransitioning, let prepared = takePreloadedPlayback() else {
            cancelTransition(keepPreloaded: false)
            return
        }
        let completedAutomix = activeAutomixPlan
        transitionTask?.cancel()
        transitionTask = nil
        isTransitioning = false
        transitionOutgoingGain = 1
        transitionIncomingGain = 0
        player?.volume = 0
        player?.pause()
        prepared.player.defaultRate = Float(playbackRate)
        prepared.player.rate = Float(playbackRate)
        transitionIncomingRate = 1
        activeAutomixPlan = nil
        historyTracker?.onTrackChanged(position: completedAutomix == nil ? max(progress, duration) : progress)
        logger.info("\(completedAutomix == nil ? "Crossfade" : "Automix", privacy: .public) handoff complete: \(prepared.track.title, privacy: .public)")
        adopt(prepared, alreadyPlaying: true)
    }

    @discardableResult
    private func adoptPreloadedImmediately() -> Bool {
        guard preloadedReady, let prepared = takePreloadedPlayback() else { return false }
        player?.pause()
        prepared.player.volume = volume
        prepared.player.playImmediately(atRate: Float(playbackRate))
        logger.info("Gapless handoff: \(prepared.track.title, privacy: .public)")
        adopt(prepared, alreadyPlaying: true)
        return true
    }

    private func adopt(_ prepared: PreparedHandoff, alreadyPlaying: Bool) {
        if currentTrack?.id != prepared.track.id {
            listeningRecorder?.onStopped()
            scrobbling?.playbackStopped()
        }
        playbackRequestID = UUID()
        lyricsTask?.cancel()
        lyricsTask = nil
        lyricsLoading = false
        fallbackRequestID = nil
        currentTrack = prepared.track
        activeTrackAliases = [prepared.track.id, prepared.sourceTrackID]
        queueIndex = prepared.queueIndex
        currentAutomixTask?.cancel()
        currentAutomixTask = nil
        currentAutomixRunning = false
        currentAutomixAnalysis = prepared.automixAnalysis
        lyrics = nil
        streamInfo = prepared.streamInfo
        skippedSilenceSeconds = 0
        prepared.player.volume = volume
        if !alreadyPlaying {
            prepared.player.playImmediately(atRate: Float(playbackRate))
        }
        activate(
            prepared.player,
            item: prepared.item,
            asset: prepared.asset,
            track: prepared.track,
            requestID: playbackRequestID,
            streamProxy: prepared.streamProxy,
            startPlayback: false,
            durationHint: prepared.duration
        )
        if let stream = prepared.resolvedStream {
            scheduleAudioCache(stream, requestID: playbackRequestID)
        }
        loadLyrics()
        loadAutoplayForCurrentTrack()
    }

    private func takePreloadedPlayback() -> PreparedHandoff? {
        guard let player = preloadedPlayer,
              let item = preloadedItem,
              let asset = preloadedAsset,
              let track = preloadedTrack,
              let queueIndex = preloadedQueueIndex else { return nil }
        preloadTask?.cancel()
        preloadTask = nil
        preloadedStatusObservation?.invalidate()
        preloadedStatusObservation = nil
        preloadedPlayerStatusObservation?.invalidate()
        preloadedPlayerStatusObservation = nil
        let prepared = PreparedHandoff(
            player: player,
            item: item,
            asset: asset,
            track: track,
            sourceTrackID: preloadedSourceTrackID ?? track.id,
            queueIndex: queueIndex,
            streamInfo: preloadedStreamInfo,
            resolvedStream: preloadedResolvedStream,
            duration: preloadedDuration,
            streamProxy: preloadedProxy,
            automixAnalysis: preloadedAutomixAnalysis
        )
        preloadedPlayer = nil
        preloadedItem = nil
        preloadedAsset = nil
        preloadedTrack = nil
        preloadedSourceTrackID = nil
        preloadedQueueIndex = nil
        preloadedStreamInfo = nil
        preloadedResolvedStream = nil
        preloadedDuration = nil
        preloadedProxy = nil
        preloadedAutomixTask?.cancel()
        preloadedAutomixTask = nil
        preloadedAutomixAnalysis = nil
        preloadedAutomixRunning = false
        preloadedReady = false
        return prepared
    }

    private func cancelTransition(keepPreloaded: Bool) {
        transitionTask?.cancel()
        transitionTask = nil
        guard isTransitioning else {
            if !keepPreloaded { resetPreloadedPlayback() }
            return
        }
        isTransitioning = false
        activeAutomixPlan = nil
        transitionIncomingRate = 1
        transitionOutgoingGain = 1
        transitionIncomingGain = 0
        player?.volume = volume
        preloadedPlayer?.pause()
        preloadedPlayer?.defaultRate = Float(playbackRate)
        preloadedPlayer?.rate = 0
        preloadedPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        preloadedPlayer?.volume = 0
        if !keepPreloaded { resetPreloadedPlayback() }
        refreshAutomixStatus()
    }

    private func resetPreloadedPlayback() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadedStatusObservation?.invalidate()
        preloadedStatusObservation = nil
        preloadedPlayerStatusObservation?.invalidate()
        preloadedPlayerStatusObservation = nil
        preloadedPlayer?.cancelPendingPrerolls()
        preloadedPlayer?.pause()
        preloadedProxy?.stop()
        preloadedPlayer = nil
        preloadedItem = nil
        preloadedAsset = nil
        preloadedTrack = nil
        preloadedSourceTrackID = nil
        preloadedQueueIndex = nil
        preloadedStreamInfo = nil
        preloadedResolvedStream = nil
        preloadedDuration = nil
        preloadedProxy = nil
        preloadedAutomixTask?.cancel()
        preloadedAutomixTask = nil
        preloadedAutomixAnalysis = nil
        preloadedAutomixRunning = false
        preloadedReady = false
        refreshAutomixStatus()
    }

    private func configureAudioEffects(
        for item: AVPlayerItem,
        spatialAudioEnabled: Bool? = nil
    ) {
        let snapshot = equalizerSnapshot
        let spatialEnabled = spatialAudioEnabled ?? self.spatialAudioEnabled
        let revision = equalizerRevision
        guard snapshot.enabled || spatialEnabled else {
            item.audioMix = nil
            if item === player?.currentItem {
                equalizerActive = false
                spatialAudioActive = false
            }
            return
        }
        if item.audioMix != nil {
            if item === player?.currentItem {
                equalizerActive = snapshot.enabled
                spatialAudioActive = spatialEnabled
            }
            return
        }

        let asset = item.asset
        Task { [weak self, weak item] in
            guard let self, let item,
                  let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  equalizerRevision == revision,
                  equalizerSnapshot == snapshot,
                  self.spatialAudioEnabled == spatialEnabled else { return }
            let mix = EqualizerAudioMix.make(
                equalizer: snapshot,
                spatialAudioEnabled: spatialEnabled,
                track: track
            )
            guard equalizerRevision == revision,
                  equalizerSnapshot == snapshot,
                  self.spatialAudioEnabled == spatialEnabled else { return }
            item.audioMix = mix
            if item === player?.currentItem {
                equalizerActive = snapshot.enabled && mix != nil
                spatialAudioActive = spatialEnabled && mix != nil
            }
        }
    }

    private func prepareCompatibleFallback(for track: Track, requestID: UUID) {
        guard playbackRequestID == requestID, fallbackRequestID != requestID else { return }
        fallbackRequestID = requestID
        player?.pause()
        scrobbling?.playbackPaused()
        removeObservers()
        player = nil
        equalizerActive = false
        spatialAudioActive = false
        currentPlaybackAsset = nil
        isPlaying = false
        isLoading = true
        statusMessage = "Preparing compatible audio…"

        resolvingTask = Task { [weak self, api] in
            guard let self else { return }
            do {
                let localURL = try await api.downloadPlaybackFallback(for: track)
                try Task.checkCancellation()
                guard playbackRequestID == requestID else {
                    return
                }
                start(
                    url: localURL,
                    headers: [:],
                    for: track,
                    requestID: requestID,
                    durationHint: track.duration ?? Self.audioFileDuration(at: localURL)
                )
                let info = await Self.inspectAudioFile(
                    at: localURL,
                    sourceName: "YouTube Music cache"
                )
                guard !Task.isCancelled, playbackRequestID == requestID else { return }
                streamInfo = info
            } catch {
                guard !Task.isCancelled, playbackRequestID == requestID else { return }
                failPlayback("Could not prepare this YouTube Music stream. Try again.")
            }
        }
    }

    /// Matches Android's cache read-ahead grace period: let AVPlayer fill its
    /// opening buffer first, then fetch the complete rendition in bounded
    /// ranges. Cancelling or changing tracks cancels the same task.
    private func scheduleAudioCache(_ stream: ResolvedStream, requestID: UUID) {
        audioCacheTask?.cancel()
        audioCacheTask = Task { [weak self, api] in
            guard let self else { return }
            while !Task.isCancelled, playbackRequestID == requestID, !isPlaying {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, playbackRequestID == requestID, isPlaying else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, playbackRequestID == requestID, isPlaying else { return }
            await api.cacheResolvedStream(stream)
        }
    }

    private func stopCurrentPlayback() {
        audioCacheTask?.cancel()
        audioCacheTask = nil
        qualityUpgradeTask?.cancel()
        qualityUpgradeTask = nil
        currentAutomixTask?.cancel()
        currentAutomixTask = nil
        currentAutomixRunning = false
        currentAutomixAnalysis = nil
        cancelTransition(keepPreloaded: false)
        player?.pause()
        removeObservers()
        player = nil
        equalizerActive = false
        spatialAudioActive = false
        isPlaying = false
        isLoading = false
        refreshAutomixStatus()
    }

    private func failPlayback(_ message: String) {
        audioCacheTask?.cancel()
        audioCacheTask = nil
        cancelTransition(keepPreloaded: false)
        listeningRecorder?.onStopped()
        scrobbling?.playbackStopped()
        historyTracker?.onPlaybackFinished(position: progress)
        player?.pause()
        equalizerActive = false
        spatialAudioActive = false
        isPlaying = false
        isLoading = false
        statusMessage = nil
        errorMessage = message
        updateNowPlaying()
    }

    private func removeObservers() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        silenceAnalysisTask?.cancel()
        silenceAnalysisTask = nil
        silenceIntervals = []
        skippedSilenceIntervals = []
        streamProxy?.stop()
        streamProxy = nil
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            guard let self, currentTrack != nil, !isPlaying else { return .commandFailed }
            togglePlayback()
            return .success
        }
        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let self, isPlaying else { return .commandFailed }
            togglePlayback()
            return .success
        }
        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, currentTrack != nil else { return .commandFailed }
            togglePlayback()
            return .success
        }
        commands.nextTrackCommand.isEnabled = true
        commands.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, currentTrack != nil else { return .commandFailed }
            next()
            return .success
        }
        commands.previousTrackCommand.isEnabled = true
        commands.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, currentTrack != nil else { return .commandFailed }
            previous()
            return .success
        }
        commands.changeRepeatModeCommand.isEnabled = true
        commands.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            switch event.repeatType {
            case .off:
                setRepeatMode(.off)
            case .all:
                setRepeatMode(.all)
            case .one:
                setRepeatMode(.one)
            @unknown default:
                return .commandFailed
            }
            return .success
        }
        commands.changeShuffleModeCommand.isEnabled = true
        commands.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let self,
                  let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            setShuffle(event.shuffleType != .off)
            return .success
        }
    }

    private func restoreQueueSnapshot() {
        guard let snapshot = queueStore?.load() else { return }
        queue = snapshot.tracks
        queueIndex = snapshot.index
        currentTrack = snapshot.tracks[snapshot.index]
        activeTrackAliases = currentTrack.map { [$0.id] } ?? []
        duration = currentTrack?.duration ?? 0
        progress = Self.restoredPosition(snapshot.position, duration: duration) ?? 0
        isPlaying = false
        isLoading = false
        statusMessage = nil
        updateNowPlaying()
    }

    private func observeQueueForPersistence() {
        guard queueStore != nil else { return }
        queuePersistenceCancellable = Publishers.CombineLatest4($queue, $queueIndex, $progress, $currentTrack)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.persistQueueSnapshot()
            }
    }

    private func persistQueueSnapshot() {
        var persistedQueue = queue
        if persistedQueue.indices.contains(queueIndex),
           persistedQueue[queueIndex].id == currentTrack?.id,
           let measuredDuration = Self.validDuration(duration) {
            persistedQueue[queueIndex].duration = measuredDuration
        }
        queueStore?.save(tracks: persistedQueue, index: queueIndex, position: progress)
    }

    nonisolated private static func restoredPosition(
        _ value: TimeInterval?,
        duration: TimeInterval?
    ) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        guard let duration = validDuration(duration) else { return value }
        return min(value, duration)
    }

    private func updateNowPlaying() {
        guard let currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTrack.title,
            MPMediaItemPropertyArtist: currentTrack.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}

@MainActor
final class LibraryPreferences: ObservableObject {
    enum ToggleResult: Equatable {
        case pinned
        case unpinned
        case limitReached
    }

    static let maximumPinnedPlaylists = 5
    static let storageKey = "pinned_playlists"

    @Published private(set) var pinnedPlaylistIDs: [String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pinnedPlaylistIDs = Self.decode(defaults.string(forKey: Self.storageKey) ?? "")
    }

    func isPinned(_ browseID: String) -> Bool {
        pinnedPlaylistIDs.contains(browseID)
    }

    @discardableResult
    func toggle(_ browseID: String) -> ToggleResult {
        let cleaned = browseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .limitReached }
        if let index = pinnedPlaylistIDs.firstIndex(of: cleaned) {
            pinnedPlaylistIDs.remove(at: index)
            persist()
            return .unpinned
        }
        guard pinnedPlaylistIDs.count < Self.maximumPinnedPlaylists else { return .limitReached }
        pinnedPlaylistIDs.append(cleaned)
        persist()
        return .pinned
    }

    func unpin(_ browseID: String) {
        guard pinnedPlaylistIDs.contains(browseID) else { return }
        pinnedPlaylistIDs.removeAll { $0 == browseID }
        persist()
    }

    func replace(with browseIDs: [String]) {
        pinnedPlaylistIDs = Self.sanitized(browseIDs)
        persist()
    }

    func reload() {
        pinnedPlaylistIDs = Self.decode(defaults.string(forKey: Self.storageKey) ?? "")
    }

    func ordered(_ shelf: HomeShelf) -> HomeShelf {
        Self.ordered(shelf, pinnedPlaylistIDs: pinnedPlaylistIDs)
    }

    static func ordered(_ shelf: HomeShelf, pinnedPlaylistIDs: [String]) -> HomeShelf {
        guard shelf.title.caseInsensitiveCompare("Playlists") == .orderedSame,
              !pinnedPlaylistIDs.isEmpty else { return shelf }
        let itemsByID = Dictionary(shelf.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pinnedItems = pinnedPlaylistIDs.compactMap { itemsByID[$0] }
        guard !pinnedItems.isEmpty else { return shelf }
        let pinnedSet = Set(pinnedItems.map(\.id))
        return HomeShelf(
            title: shelf.title,
            subtitle: shelf.subtitle,
            items: pinnedItems + shelf.items.filter { !pinnedSet.contains($0.id) }
        )
    }

    static func decode(_ value: String) -> [String] {
        sanitized(value.split(separator: ",", omittingEmptySubsequences: false).map(String.init))
    }

    private static func sanitized(_ browseIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for browseID in browseIDs {
            let cleaned = browseID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            result.append(cleaned)
            if result.count == maximumPinnedPlaylists { break }
        }
        return result
    }

    private func persist() {
        defaults.set(pinnedPlaylistIDs.joined(separator: ","), forKey: Self.storageKey)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .home
    @Published var homeShelves: [HomeShelf] = []
    @Published var homeLoading = false
    @Published var homeError: String?
    @Published var exploreShelves: [HomeShelf] = []
    @Published var exploreLoading = false
    @Published var exploreError: String?
    @Published var libraryShelves: [HomeShelf] = []
    @Published var libraryLoading = false
    @Published var libraryError: String?
    @Published var showHistory = false
    @Published private(set) var historyTracks: [Track] = []
    @Published private(set) var historyLoading = false
    @Published var historyError: String?
    @Published var selectedBrowseItem: BrowseItem?
    @Published var browseTracks: [Track] = []
    @Published var browseLoading = false
    @Published var browseError: String?
    @Published private(set) var selectedPlaylistOwned = false
    @Published var query = ""
    @Published var filter: SearchFilter = .songs
    @Published var results: [SearchResult] = []
    @Published var searchLoading = false
    @Published var searchError: String?
    @Published var searchHistory: [String] = []
    @Published var showOpenLink = false
    @Published private(set) var linkLoading = false
    @Published var linkError: String?
    @Published private(set) var nowPlayingRequestID: UUID?
    @Published private(set) var localTracks: [Track] = []
    @Published private(set) var localFolders: [LocalLibraryFolder] = []
    @Published private(set) var localLibraryLoading = false
    @Published var localLibraryError: String?
    @Published private(set) var youtubeSignedIn = false
    @Published var showLogin = false
    @Published private(set) var likeStatuses: [String: LikeStatus] = [:]
    @Published private(set) var ratingInFlight: Set<String> = []
    @Published private(set) var userPlaylists: [UserPlaylist] = []
    @Published private(set) var playlistsLoading = false
    @Published var showCreatePlaylist = false
    @Published var playlistTrack: Track?
    @Published private(set) var playlistActionInFlight = false
    @Published var accountActionError: String?
    @Published private(set) var playlistTitleOverrides: [String: String] = [:]
    @Published private(set) var resolvedTrackLinks: [String: Track] = [:]
    @Published private(set) var trackLinksInFlight: Set<String> = []
    @Published var pendingBackupCandidate: BackupCandidate?
    @Published private(set) var backupBusy = false
    @Published private(set) var backupStatus: BackupOperationStatus?
    @Published private(set) var audioCacheSnapshot = AudioStreamCache.Snapshot(usedBytes: 0, fileCount: 0)
    @Published private(set) var audioCacheBusy = false

    let api: YouTubeMusicAPI
    let player: PlaybackController
    let downloads: DownloadManager
    let playbackSettings: PlaybackSettings
    let lyricsSettings: LyricsSettings
    let sources: SourceModuleManager
    let replay: ReplayViewModel
    let scrobbling: ScrobblingManager
    let backup: BackupManager
    let canvas: CanvasController
    let canvasRepository: CanvasRepository
    let canvasClipCache: CanvasClipCache
    let spotifyCanvasSettings: SpotifyCanvasSettings
    let equalizer: EqualizerSettings
    let libraryPreferences: LibraryPreferences

    private let libraryFile: URL
    private let localLibraryIndexer: LocalMediaIndexer
    private let historyKey = "BitChord.searchHistory"
    private let authStore: AuthStore
    private var importedTracks: [Track] = []
    private var folderTracks: [String: [Track]] = [:]
    private var localLibraryTask: Task<Void, Never>?
    private var musicLinkTask: Task<Void, Never>?
    private var musicLinkGeneration: UUID?

    init() {
        let authStore = AuthStore()
        self.authStore = authStore
        let playbackSettings = PlaybackSettings()
        let lyricsSettings = LyricsSettings()
        let api = YouTubeMusicAPI(lyricsSettings: lyricsSettings)
        let sources = SourceModuleManager()
        let scrobbling = ScrobblingManager()
        let listeningStats = ListeningStatsStore()
        let replayGenresEnabled = UserDefaults.standard.object(forKey: ArtistFactsStore.settingKey) as? Bool ?? true
        let artistFacts = ArtistFactsStore(enabled: replayGenresEnabled)
        let replay = ReplayViewModel(store: listeningStats, artistFacts: artistFacts)
        let spotifyCredentials = SpotifyCanvasCredentialStore()
        let spotifyCanvasSettings = SpotifyCanvasSettings(credentials: spotifyCredentials)
        let spotifyTransport = URLSessionSpotifyCanvasTransport()
        let spotifyTokens = SpotifyCanvasTokenManager(
            credentials: spotifyCredentials,
            transport: spotifyTransport
        )
        let canvasHTTP = URLSessionCanvasHTTPClient()
        let canvasRepository = CanvasRepository(providers: [
            AppleMusicCanvasProvider(http: canvasHTTP),
            TidalCanvasProvider(http: canvasHTTP),
            CommunityCanvasProvider(http: canvasHTTP),
            SpotifyCanvasProvider(tokenProvider: spotifyTokens, transport: spotifyTransport)
        ])
        let canvasClipCache = CanvasClipCache()
        let canvas = CanvasController(repository: canvasRepository, clipCache: canvasClipCache)
        let equalizer = EqualizerSettings()
        let libraryPreferences = LibraryPreferences()
        let listeningCoordinator = ListeningStatsCoordinator(
            store: listeningStats,
            artistFacts: artistFacts,
            replay: replay
        )
        let listeningRecorder = ListeningRecorder(
            onRecord: { track, seconds, countsAsPlay, date in
                listeningCoordinator.record(track, seconds: seconds, countsAsPlay: countsAsPlay, at: date)
            },
            onFlush: listeningCoordinator.flush
        )
        let playbackResolver = SourceAwarePlaybackResolver(youtube: api, sources: sources)
        let downloadResolver = SourceAwareTrackDownloader(youtube: api, sources: sources)
        let downloads = DownloadManager(
            downloader: downloadResolver,
            lyricsProvider: api,
            artworkProvider: URLSessionDownloadArtworkProvider(),
            downloadsAllowedNow: { [weak playbackSettings] in
                playbackSettings?.downloadsAllowedNow ?? true
            }
        )
        let backup = BackupManager(
            listening: listeningStats,
            playbackSettings: playbackSettings,
            downloads: downloads,
            replay: replay,
            scrobbling: scrobbling,
            lyricsSettings: lyricsSettings,
            equalizer: equalizer,
            libraryPreferences: libraryPreferences
        )
        self.api = api
        self.playbackSettings = playbackSettings
        self.lyricsSettings = lyricsSettings
        self.sources = sources
        self.replay = replay
        self.scrobbling = scrobbling
        self.backup = backup
        self.canvas = canvas
        self.canvasRepository = canvasRepository
        self.canvasClipCache = canvasClipCache
        self.spotifyCanvasSettings = spotifyCanvasSettings
        self.equalizer = equalizer
        self.libraryPreferences = libraryPreferences
        let player = PlaybackController(
            api: playbackResolver,
            autoplayAPI: api,
            historyAPI: api,
            listeningRecorder: listeningRecorder,
            scrobbling: scrobbling,
            queueStore: PlaybackQueueStore()
        )
        self.player = player
        self.downloads = downloads

        playbackSettings.onChange = { [weak api, weak player, weak sources] quality, skipSilence, crossfadeSeconds in
            api?.setPlaybackQuality(quality)
            sources?.setPlaybackQuality(quality)
            player?.setSkipSilence(skipSilence)
            player?.setCrossfade(seconds: crossfadeSeconds)
        }
        playbackSettings.onAutomixChange = { [weak player] enabled in
            player?.setAutomix(enabled: enabled)
        }
        playbackSettings.onAutoplayChange = { [weak player] enabled, avoidRepeatedSuggestions in
            player?.setAutoplay(
                enabled: enabled,
                avoidRepeatedSuggestions: avoidRepeatedSuggestions
            )
        }
        playbackSettings.onSpatialAudioChange = { [weak player] enabled in
            player?.setSpatialAudio(enabled: enabled)
        }
        playbackSettings.onVideoAudioConversionChange = { [weak api] enabled in
            api?.setConvertVideoToAudio(enabled)
        }
        playbackSettings.onPlaybackSpeedChange = { [weak player] speed in
            player?.setPlaybackRate(speed)
        }
        playbackSettings.applyCurrentSettings()
        equalizer.onChange = { [weak player] snapshot in
            player?.setEqualizer(snapshot)
        }
        equalizer.applyCurrentSettings()

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        libraryFile = appSupport.appendingPathComponent("library.json")
        localLibraryIndexer = LocalMediaIndexer(
            artworkDirectory: appSupport.appendingPathComponent("Artwork", isDirectory: true)
        )
        playbackSettings.onAudioCacheLimitChange = { [weak self, weak api] bytes in
            guard let api else { return }
            Task { @MainActor [weak self, weak api] in
                guard let api else { return }
                let snapshot = await api.setAudioCacheLimit(bytes)
                self?.audioCacheSnapshot = snapshot
            }
        }
        playbackSettings.onAudioCacheLimitChange?(playbackSettings.audioCacheLimitBytes)
        player.onHistoryRegistered = { [weak self] in
            guard let self else { return }
            if showHistory { loadHistory() }
            refreshHome()
        }
        loadLibrary()
        refreshLocalLibrary()
        searchHistory = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        refreshHome()
        refreshExplore()
        restoreYouTubeSession()
        refreshAudioCacheSnapshot()
    }

    func refreshAudioCacheSnapshot() {
        Task { @MainActor [weak self, weak api] in
            guard let self, let api else { return }
            audioCacheSnapshot = await api.audioCacheSnapshot()
        }
    }

    func clearAudioCache() {
        guard !audioCacheBusy else { return }
        audioCacheBusy = true
        Task { @MainActor [weak self, weak api] in
            guard let self, let api else { return }
            audioCacheSnapshot = await api.clearAudioCache()
            audioCacheBusy = false
        }
    }

    func openMusicLink(_ url: URL) {
        openMusicLink(url.absoluteString)
    }

    func openMusicLink(_ rawValue: String) {
        guard let request = MusicLinkParser.parse(rawValue) else {
            linkError = "Paste a YouTube or YouTube Music song, album, artist, playlist or search link."
            return
        }
        showOpenLink = false
        linkError = nil
        musicLinkTask?.cancel()
        let generation = UUID()
        musicLinkGeneration = generation
        linkLoading = true
        browseLoading = false
        if case .page = request {
            selectedBrowseItem = nil
            browseTracks = []
            browseError = nil
            browseLoading = true
        }

        musicLinkTask = Task { @MainActor [weak self, api] in
            guard let self else { return }
            do {
                switch request {
                case .track(let videoID):
                    let track = try await api.trackLinks(for: videoID)
                    try Task.checkCancellation()
                    guard musicLinkGeneration == generation else { return }
                    play(track, queue: [track])
                    nowPlayingRequestID = UUID()

                case .page(let browseID):
                    let page = try await api.page(for: browseID)
                    try Task.checkCancellation()
                    guard musicLinkGeneration == generation else { return }
                    browseTracks = page.tracks
                    browseLoading = false
                    browseError = page.tracks.isEmpty
                        ? "YouTube Music returned no playable tracks for this page."
                        : nil
                    selectedPlaylistOwned = api.isEditablePlaylist(page.item.id)
                    selectedBrowseItem = page.item

                case .search(let term):
                    guard musicLinkGeneration == generation else { return }
                    query = term
                    filter = .songs
                    section = .search
                    submitSearch()
                }
                guard musicLinkGeneration == generation else { return }
                linkLoading = false
            } catch is CancellationError {
                // A newer link owns the loading state.
            } catch {
                guard musicLinkGeneration == generation else { return }
                linkLoading = false
                browseLoading = false
                linkError = "Could not open that YouTube Music link. \(error.localizedDescription)"
            }
        }
    }

    func exportBackup() {
        guard !backupBusy else { return }
        let panel = NSSavePanel()
        panel.title = "Export Lilt Backup"
        panel.message = "Settings, search history and Replay. Credentials and audio files are never included."
        panel.nameFieldStringValue = BackupManager.suggestedFilename()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }

        backupBusy = true
        backupStatus = nil
        Task { [weak self, backup] in
            guard let self else { return }
            do {
                let data = try await backup.export(searchHistory: searchHistory)
                try data.write(to: target, options: .atomic)
                let preview = try backup.inspect(data)
                let months = preview.months == 1 ? "1 month" : "\(preview.months) months"
                backupStatus = BackupOperationStatus(
                    message: "Exported \(months) and \(preview.compatibleSettings) settings to \(target.lastPathComponent).",
                    isError: false
                )
            } catch {
                backupStatus = BackupOperationStatus(
                    message: "Export failed: \(error.localizedDescription)",
                    isError: true
                )
            }
            backupBusy = false
        }
    }

    func chooseBackupForRestore() {
        guard !backupBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Lilt Backup"
        panel.message = "The file is validated and previewed before anything is replaced."
        panel.allowedContentTypes = [.json, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }

        backupBusy = true
        backupStatus = nil
        Task { [weak self, backup] in
            guard let self else { return }
            do {
                let resource = try source.resourceValues(forKeys: [.fileSizeKey])
                if let size = resource.fileSize, size > 25 * 1_024 * 1_024 {
                    throw BitChordBackupError.tooLarge
                }
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                let preview = try backup.inspect(data)
                pendingBackupCandidate = BackupCandidate(
                    data: data,
                    sourceURL: source,
                    preview: preview
                )
            } catch {
                backupStatus = BackupOperationStatus(
                    message: "Import failed: \(error.localizedDescription)",
                    isError: true
                )
            }
            backupBusy = false
        }
    }

    func restoreBackup(_ candidate: BackupCandidate) {
        guard !backupBusy, pendingBackupCandidate?.id == candidate.id else { return }
        backupBusy = true
        backupStatus = nil
        Task { [weak self, backup, replay] in
            guard let self else { return }
            do {
                let result = try await backup.restore(candidate.data)
                searchHistory = result.searchHistory
                UserDefaults.standard.set(searchHistory, forKey: historyKey)
                libraryShelves = libraryShelves.map(libraryPreferences.ordered)
                replay.markRecorded()
                await replay.refresh()
                let months = result.preview.months == 1 ? "1 month" : "\(result.preview.months) months"
                backupStatus = BackupOperationStatus(
                    message: "Restored \(months) from backup version \(result.preview.versionName).",
                    isError: false
                )
                pendingBackupCandidate = nil
            } catch {
                backupStatus = BackupOperationStatus(
                    message: "Import failed: \(error.localizedDescription)",
                    isError: true
                )
            }
            backupBusy = false
        }
    }

    var libraryItemCount: Int {
        localTracks.count + libraryShelves.reduce(0) { $0 + $1.items.count }
    }

    var downloadCount: Int {
        downloads.saved.count
    }

    private func restoreYouTubeSession() {
        let authStore = self.authStore
        Task { [weak self] in
            let cookie = await Task.detached(priority: .userInitiated) {
                authStore.cookie
            }.value
            guard let self, let cookie, AuthStore.hasAPISID(cookie) else { return }
            api.setCookie(cookie)
            youtubeSignedIn = true
            refreshHome()
            refreshExplore()
            refreshLibrary()
            loadUserPlaylists()
        }
    }

    func completeYouTubeLogin(cookie: String) {
        guard AuthStore.hasAPISID(cookie) else { return }
        authStore.cookie = cookie
        api.setCookie(cookie)
        youtubeSignedIn = true
        showLogin = false
        refreshHome()
        refreshExplore()
        refreshLibrary()
        loadUserPlaylists()
    }

    func signOutYouTube() {
        authStore.signOut()
        api.setCookie(nil)
        youtubeSignedIn = false
        libraryShelves = []
        userPlaylists = []
        showCreatePlaylist = false
        likeStatuses = [:]
        showHistory = false
        historyTracks = []
        historyError = nil
        libraryError = nil
        selectedBrowseItem = nil
        refreshHome()
        refreshExplore()
    }

    func playHomeMix() {
        let liveTracks = homeShelves.flatMap { $0.items.compactMap(\.track) }
        if let first = liveTracks.first {
            play(first, queue: liveTracks)
            return
        }

        let mix = homeShelves
            .flatMap(\.items)
            .compactMap(\.browseItem)
            .first { $0.kind == .playlist || $0.kind == .other }
        guard let mix else {
            section = .search
            return
        }

        Task { [weak self, api] in
            guard let self else { return }
            do {
                let tracks = try await api.tracks(for: mix.id)
                guard let first = tracks.first else { throw YouTubeMusicAPIError.noPlayableStream }
                play(first, queue: tracks)
            } catch {
                player.errorMessage = "Could not load this YouTube Music mix. Try again after signing in."
            }
        }
    }

    func play(_ track: Track, queue: [Track]? = nil) {
        let playableTrack = downloads.playableTrack(for: track)
        let playableQueue = queue.map(downloads.playableQueue)
        player.play(playableTrack, queue: playableQueue)
    }

    func playShuffled(_ tracks: [Track]) {
        player.playShuffled(downloads.playableQueue(tracks))
    }

    func refreshHome() {
        homeLoading = true
        homeError = nil
        Task { [weak self] in
            await self?.finishHomeRefresh()
        }
    }

    func refreshHomeFromPull() async {
        guard !homeLoading else { return }
        homeLoading = true
        homeError = nil
        await finishHomeRefresh()
    }

    private func finishHomeRefresh() async {
        do {
            let shelves = try await api.home()
            if !shelves.isEmpty { homeShelves = shelves }
            homeLoading = false
        } catch {
            homeLoading = false
            homeError = "Could not load YouTube Music right now."
        }
    }

    func refreshExplore() {
        exploreLoading = true
        exploreError = nil
        Task { [weak self] in
            await self?.finishExploreRefresh()
        }
    }

    func refreshExploreFromPull() async {
        guard !exploreLoading else { return }
        exploreLoading = true
        exploreError = nil
        await finishExploreRefresh()
    }

    private func finishExploreRefresh() async {
        let shelves = await api.explore()
        if shelves.isEmpty {
            exploreError = "Nothing to explore right now."
        } else {
            exploreShelves = shelves
        }
        exploreLoading = false
    }

    func refreshLibrary() {
        guard youtubeSignedIn else {
            libraryShelves = []
            libraryLoading = false
            libraryError = nil
            return
        }
        libraryLoading = true
        libraryError = nil
        Task { [weak self] in
            await self?.finishLibraryRefresh()
        }
        loadUserPlaylists()
    }

    func refreshLibraryFromPull() async {
        guard youtubeSignedIn, !libraryLoading else { return }
        libraryLoading = true
        libraryError = nil
        await finishLibraryRefresh()
        loadUserPlaylists()
    }

    private func finishLibraryRefresh() async {
        do {
            libraryShelves = try await api.library().map(libraryPreferences.ordered)
            libraryLoading = false
        } catch {
            libraryLoading = false
            libraryError = error.localizedDescription
        }
    }

    func openHistory() {
        guard youtubeSignedIn else {
            showLogin = true
            return
        }
        showHistory = true
        loadHistory()
    }

    func loadHistory() {
        guard youtubeSignedIn, !historyLoading else {
            if !youtubeSignedIn {
                historyTracks = []
                historyError = "Sign in to see what you've been listening to."
            }
            return
        }
        historyLoading = true
        historyError = nil
        Task { [weak self, api] in
            guard let self else { return }
            do {
                historyTracks = try await api.history()
                if historyTracks.isEmpty { historyError = "Nothing played yet." }
            } catch {
                historyError = error.localizedDescription
            }
            historyLoading = false
        }
    }

    func openBrowseItem(_ item: BrowseItem) {
        selectedBrowseItem = item
        selectedPlaylistOwned = false
        browseTracks = []
        browseLoading = true
        browseError = nil
        Task { [weak self, api] in
            guard let self else { return }
            do {
                let tracks = try await api.tracks(for: item.id)
                guard selectedBrowseItem?.id == item.id else { return }
                browseTracks = tracks
                selectedPlaylistOwned = api.isEditablePlaylist(item.id)
                if item.id == "LM" || item.id == "VLLM" {
                    for track in tracks {
                        if let videoID = track.videoID { likeStatuses[videoID] = .like }
                    }
                }
                browseLoading = false
                if tracks.isEmpty { browseError = "YouTube Music returned no playable tracks for this page." }
            } catch {
                guard selectedBrowseItem?.id == item.id else { return }
                browseLoading = false
                browseError = error.localizedDescription
            }
        }
    }

    func submitSearch() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let submittedFilter = filter
        searchHistory.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
        searchHistory.insert(term, at: 0)
        searchHistory = Array(searchHistory.prefix(12))
        UserDefaults.standard.set(searchHistory, forKey: historyKey)
        searchLoading = true
        searchError = nil
        section = .search

        Task { [weak self, api, sources] in
            guard let self else { return }
            let youtubeTask = Task { try await api.search(query: term, filter: submittedFilter) }
            let sourceTask = Task {
                submittedFilter == .songs
                    ? await sources.searchJioSaavn(query: term)
                    : []
            }
            let sourceTracks = await sourceTask.value
            do {
                let youtubeResults = try await youtubeTask.value
                guard query.trimmingCharacters(in: .whitespacesAndNewlines) == term,
                      filter == submittedFilter else { return }
                results = sourceTracks.map(SearchResult.track) + youtubeResults
                searchLoading = false
            } catch {
                guard query.trimmingCharacters(in: .whitespacesAndNewlines) == term,
                      filter == submittedFilter else { return }
                searchLoading = false
                if sourceTracks.isEmpty {
                    searchError = error.localizedDescription
                } else {
                    results = sourceTracks.map(SearchResult.track)
                }
            }
        }
    }

    func useHistory(_ term: String) {
        query = term
        submitSearch()
    }

    func importAudio() {
        let panel = NSOpenPanel()
        panel.title = "Add music to Lilt"
        panel.message = "Selected files are copied into Lilt. Their tags and artwork stay intact."
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }

        let sources = panel.urls
        let destinationDirectory = importedDirectory
        let indexer = localLibraryIndexer
        localLibraryLoading = true
        localLibraryError = nil

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> ([URL], [String]) in
                var copied: [URL] = []
                var failures: [String] = []
                do {
                    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                } catch {
                    return ([], ["Could not create the imported music folder."])
                }

                for source in sources where LocalMediaIndexer.isSupportedAudioFile(source) {
                    var destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        let stem = source.deletingPathExtension().lastPathComponent
                        let suffix = String(UUID().uuidString.prefix(8))
                        destination = destinationDirectory
                            .appendingPathComponent("\(stem) \(suffix)")
                            .appendingPathExtension(source.pathExtension)
                    }
                    do {
                        try FileManager.default.copyItem(at: source, to: destination)
                        copied.append(destination)
                    } catch {
                        failures.append(source.lastPathComponent)
                    }
                }
                return (copied, failures)
            }.value

            guard let self else { return }
            var tracks: [Track] = []
            for url in result.0 {
                if let track = await indexer.track(at: url, folderID: nil) {
                    tracks.append(track)
                }
            }
            importedTracks = deduplicatedByPath(importedTracks + tracks)
            rebuildLocalTracks()
            saveLibrary()
            localLibraryLoading = false
            if !result.1.isEmpty {
                localLibraryError = "Could not import: \(result.1.joined(separator: ", "))"
            }
        }
    }

    func addLocalFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add Music Folder"
        panel.message = "Lilt indexes this folder in place. Original files are never moved or deleted."
        panel.prompt = "Add Folder"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }

        let known = Set(localFolders.map(\.id))
        localFolders.append(contentsOf: panel.urls
            .map { LocalLibraryFolder(url: $0) }
            .filter { !known.contains($0.id) })
        localFolders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        saveLibrary()
        refreshLocalLibrary()
    }

    func refreshLocalLibrary() {
        localLibraryTask?.cancel()
        let imported = importedTracks
        let folders = localFolders
        let indexer = localLibraryIndexer
        var downloadsByPath: [String: Track] = [:]
        for record in downloads.saved {
            downloadsByPath[record.fileURL.standardizedFileURL.path] = record.playableTrack
        }

        localLibraryLoading = true
        localLibraryError = nil
        localLibraryTask = Task { [weak self] in
            guard let self else { return }
            var refreshedImported: [Track] = []
            for track in imported {
                guard !Task.isCancelled else { return }
                if let refreshed = await indexer.refreshedTrack(track) {
                    refreshedImported.append(refreshed)
                }
            }

            var scanned: [String: [Track]] = [:]
            var unavailable: [String] = []
            for folder in folders {
                guard !Task.isCancelled else { return }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    unavailable.append(folder.name)
                    scanned[folder.id] = []
                    continue
                }

                let indexed = await indexer.tracks(in: folder)
                scanned[folder.id] = indexed.map { track in
                    guard let path = track.localPath,
                          let downloaded = downloadsByPath[URL(fileURLWithPath: path).standardizedFileURL.path] else {
                        return track
                    }
                    return Track(
                        videoID: downloaded.videoID,
                        title: downloaded.title,
                        artist: downloaded.artist,
                        album: downloaded.album ?? track.album,
                        artworkURL: downloaded.artworkURL ?? track.artworkURL,
                        duration: downloaded.duration ?? track.duration,
                        localPath: track.localPath,
                        sourceURL: downloaded.sourceURL,
                        setVideoID: downloaded.setVideoID,
                        localFolderID: folder.id
                    )
                }
            }

            guard !Task.isCancelled else { return }
            importedTracks = deduplicatedByPath(refreshedImported)
            folderTracks = scanned
            rebuildLocalTracks()
            saveLibrary()
            localLibraryLoading = false
            if !unavailable.isEmpty {
                localLibraryError = "Folder unavailable: \(unavailable.joined(separator: ", "))"
            }
        }
    }

    func removeLocalTrack(_ track: Track) {
        guard track.localFolderID == nil else { return }
        importedTracks.removeAll { $0.id == track.id }
        if let path = track.localPath {
            let file = URL(fileURLWithPath: path).standardizedFileURL
            let ownedRoot = importedDirectory.standardizedFileURL.path + "/"
            if file.path.hasPrefix(ownedRoot) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        rebuildLocalTracks()
        saveLibrary()
    }

    func removeLocalFolder(_ folderID: String) {
        localFolders.removeAll { $0.id == folderID }
        folderTracks.removeValue(forKey: folderID)
        rebuildLocalTracks()
        saveLibrary()
    }

    func revealLocalTrack(_ track: Track) {
        guard let path = track.localPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func revealLocalFolder(_ folderID: String) {
        guard let folder = localFolders.first(where: { $0.id == folderID }) else { return }
        NSWorkspace.shared.open(folder.url)
    }

    func localCollections(_ kind: LocalMediaCollection.Kind) -> [LocalMediaCollection] {
        LocalLibraryOrganizer.collections(kind: kind, tracks: localTracks, folders: localFolders)
    }

    func clearSearch() {
        query = ""
        results = []
        searchError = nil
    }

    func likeStatus(for track: Track) -> LikeStatus {
        guard let videoID = track.videoID else { return .indifferent }
        return likeStatuses[videoID] ?? .indifferent
    }

    func toggleLike(_ track: Track) {
        setRating(track, status: likeStatus(for: track) == .like ? .indifferent : .like)
    }

    func toggleDislike(_ track: Track) {
        setRating(track, status: likeStatus(for: track) == .dislike ? .indifferent : .dislike)
    }

    func setRating(_ track: Track, status: LikeStatus) {
        guard youtubeSignedIn else {
            showLogin = true
            return
        }
        guard let videoID = track.videoID, !ratingInFlight.contains(videoID) else { return }
        let previous = likeStatuses[videoID] ?? .indifferent
        likeStatuses[videoID] = status
        ratingInFlight.insert(videoID)

        Task { [weak self, api] in
            guard let self else { return }
            do {
                try await api.rate(videoID: videoID, status: status)
                ratingInFlight.remove(videoID)
                syncLikedCollection(track, status: status)
            } catch {
                likeStatuses[videoID] = previous
                ratingInFlight.remove(videoID)
                accountActionError = error.localizedDescription
            }
        }
    }

    func loadUserPlaylists() {
        guard youtubeSignedIn, !playlistsLoading else { return }
        playlistsLoading = true
        Task { [weak self, api] in
            guard let self else { return }
            do {
                userPlaylists = try await api.userPlaylists()
            } catch {
                accountActionError = error.localizedDescription
            }
            playlistsLoading = false
        }
    }

    func presentPlaylistPicker(for track: Track) {
        guard youtubeSignedIn else {
            showLogin = true
            return
        }
        playlistTrack = track
        if userPlaylists.isEmpty { loadUserPlaylists() }
    }

    func add(_ track: Track, to playlist: UserPlaylist) {
        guard let videoID = track.videoID, !playlistActionInFlight else { return }
        playlistActionInFlight = true
        Task { [weak self, api] in
            guard let self else { return }
            do {
                let added = try await api.addToPlaylist(playlistID: playlist.playlistID, videoIDs: [videoID])
                if selectedBrowseItem?.id == playlist.browseID {
                    var addedTrack = track
                    addedTrack.setVideoID = added[videoID]
                    browseTracks.append(addedTrack)
                }
                playlistActionInFlight = false
                playlistTrack = nil
            } catch {
                playlistActionInFlight = false
                accountActionError = error.localizedDescription
            }
        }
    }

    func createPlaylist(title: String, privacy: PlaylistPrivacy, seededWith track: Track?) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !playlistActionInFlight else { return }
        let videoIDs = track?.videoID.map { [$0] } ?? []
        playlistActionInFlight = true
        Task { [weak self, api] in
            guard let self else { return }
            do {
                let playlistID = try await api.createPlaylist(title: name, privacy: privacy, videoIDs: videoIDs)
                let created = UserPlaylist(
                    playlistID: playlistID,
                    title: name,
                    subtitle: track == nil ? "" : "1 song",
                    artworkURL: track?.artworkURL
                )
                api.markEditablePlaylist(created.browseID)
                userPlaylists = [created] + userPlaylists.filter { $0.playlistID != created.playlistID }
                insertLibraryPlaylist(created)
                playlistActionInFlight = false
                playlistTrack = nil
                showCreatePlaylist = false
            } catch {
                playlistActionInFlight = false
                accountActionError = error.localizedDescription
            }
        }
    }

    func title(for item: BrowseItem) -> String {
        playlistTitleOverrides[item.id] ?? item.title
    }

    func trackWithResolvedLinks(_ track: Track) -> Track {
        guard let videoID = track.videoID, let links = resolvedTrackLinks[videoID] else { return track }
        return track.mergingBrowseLinks(from: links)
    }

    func isResolvingLinks(for track: Track) -> Bool {
        track.videoID.map(trackLinksInFlight.contains) == true
    }

    func resolveTrackLinksIfNeeded(_ track: Track) {
        guard let videoID = track.videoID,
              track.artistBrowseID == nil || track.albumBrowseID == nil,
              resolvedTrackLinks[videoID] == nil,
              !trackLinksInFlight.contains(videoID) else { return }
        trackLinksInFlight.insert(videoID)
        Task { [weak self, api] in
            guard let self else { return }
            do {
                resolvedTrackLinks[videoID] = try await api.trackLinks(for: videoID)
            } catch {
                // Missing catalogue links are not a playback error. The menu
                // simply omits destinations YouTube did not provide.
            }
            trackLinksInFlight.remove(videoID)
        }
    }

    func openAlbum(for track: Track) {
        let linked = trackWithResolvedLinks(track)
        guard let browseID = linked.albumBrowseID else {
            resolveTrackLinksIfNeeded(track)
            return
        }
        presentLinkedBrowseItem(BrowseItem(
            id: browseID,
            title: linked.album?.isEmpty == false ? linked.album! : linked.title,
            subtitle: linked.artist,
            artworkURL: linked.artworkURL,
            kind: .album
        ))
    }

    func openArtist(for track: Track) {
        let linked = trackWithResolvedLinks(track)
        guard let browseID = linked.artistBrowseID else {
            resolveTrackLinksIfNeeded(track)
            return
        }
        presentLinkedBrowseItem(BrowseItem(
            id: browseID,
            title: linked.artist,
            subtitle: "Artist",
            artworkURL: nil,
            kind: .artist
        ))
    }

    private func presentLinkedBrowseItem(_ item: BrowseItem) {
        selectedBrowseItem = nil
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self else { return }
            openBrowseItem(item)
        }
    }

    func isPinned(_ item: BrowseItem) -> Bool {
        item.kind == .playlist && libraryPreferences.isPinned(item.id)
    }

    func togglePinned(_ item: BrowseItem) {
        guard item.kind == .playlist else { return }
        switch libraryPreferences.toggle(item.id) {
        case .limitReached:
            accountActionError = "Only \(LibraryPreferences.maximumPinnedPlaylists) playlists can be pinned."
        case .pinned, .unpinned:
            libraryShelves = libraryShelves.map(libraryPreferences.ordered)
        }
    }

    func renameSelectedPlaylist(to title: String) {
        guard selectedPlaylistOwned, let item = selectedBrowseItem else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !playlistActionInFlight else { return }
        let previous = playlistTitleOverrides[item.id]
        playlistTitleOverrides[item.id] = name
        playlistActionInFlight = true
        Task { [weak self, api] in
            guard let self else { return }
            do {
                try await api.renamePlaylist(playlistID: item.id, title: name)
                let rawID = item.id.hasPrefix("VL") ? String(item.id.dropFirst(2)) : item.id
                userPlaylists = userPlaylists.map {
                    guard $0.playlistID == rawID else { return $0 }
                    var copy = $0
                    copy.title = name
                    return copy
                }
                replaceLibraryPlaylist(browseID: item.id, title: name)
            } catch {
                if let previous { playlistTitleOverrides[item.id] = previous }
                else { playlistTitleOverrides.removeValue(forKey: item.id) }
                accountActionError = error.localizedDescription
            }
            playlistActionInFlight = false
        }
    }

    func deleteSelectedPlaylist() {
        guard selectedPlaylistOwned, let item = selectedBrowseItem, !playlistActionInFlight else { return }
        playlistActionInFlight = true
        Task { [weak self, api] in
            guard let self else { return }
            do {
                try await api.deletePlaylist(playlistID: item.id)
                let rawID = item.id.hasPrefix("VL") ? String(item.id.dropFirst(2)) : item.id
                userPlaylists.removeAll { $0.playlistID == rawID }
                libraryPreferences.unpin(item.id)
                libraryShelves = libraryShelves.compactMap { shelf in
                    let items = shelf.items.filter { $0.browseItem?.id != item.id }
                    return items.isEmpty ? nil : HomeShelf(title: shelf.title, subtitle: shelf.subtitle, items: items)
                }
                selectedBrowseItem = nil
            } catch {
                accountActionError = error.localizedDescription
            }
            playlistActionInFlight = false
        }
    }

    func removeFromSelectedPlaylist(_ track: Track) {
        guard selectedPlaylistOwned, let item = selectedBrowseItem,
              track.setVideoID != nil, !playlistActionInFlight else { return }
        playlistActionInFlight = true
        Task { [weak self, api] in
            guard let self else { return }
            do {
                try await api.removeFromPlaylist(playlistID: item.id, track: track)
                browseTracks.removeAll { $0.setVideoID == track.setVideoID }
            } catch {
                accountActionError = error.localizedDescription
            }
            playlistActionInFlight = false
        }
    }

    private func syncLikedCollection(_ track: Track, status: LikeStatus) {
        guard selectedBrowseItem?.id == "LM" || selectedBrowseItem?.id == "VLLM" else { return }
        browseTracks = Self.likedCollectionTracks(browseTracks, applying: status, to: track)
    }

    nonisolated static func likedCollectionTracks(
        _ tracks: [Track],
        applying status: LikeStatus,
        to track: Track
    ) -> [Track] {
        guard let videoID = track.videoID else { return tracks }
        if status == .like {
            guard !tracks.contains(where: { $0.videoID == videoID }) else { return tracks }
            return [track] + tracks
        }
        return tracks.filter { $0.videoID != videoID }
    }

    private func replaceLibraryPlaylist(browseID: String, title: String) {
        libraryShelves = libraryShelves.map { shelf in
            let items = shelf.items.map { item -> ShelfItem in
                guard let browse = item.browseItem, browse.id == browseID else { return item }
                let renamed = BrowseItem(
                    id: browse.id,
                    title: title,
                    subtitle: browse.subtitle,
                    artworkURL: browse.artworkURL,
                    kind: browse.kind
                )
                return ShelfItem(
                    title: title,
                    subtitle: item.subtitle,
                    artworkURL: item.artworkURL,
                    track: item.track,
                    browseItem: renamed
                )
            }
            return HomeShelf(title: shelf.title, subtitle: shelf.subtitle, items: items)
        }
    }

    private func insertLibraryPlaylist(_ playlist: UserPlaylist) {
        let browse = BrowseItem(
            id: playlist.browseID,
            title: playlist.title,
            subtitle: playlist.subtitle,
            artworkURL: playlist.artworkURL,
            kind: .playlist
        )
        let item = ShelfItem(
            title: playlist.title,
            subtitle: playlist.subtitle,
            artworkURL: playlist.artworkURL,
            browseItem: browse
        )
        if let index = libraryShelves.firstIndex(where: { $0.title == "Playlists" }) {
            let existing = libraryShelves[index]
            let items = [item] + existing.items.filter { $0.browseItem?.id != playlist.browseID }
            libraryShelves[index] = HomeShelf(title: existing.title, subtitle: existing.subtitle, items: items)
        } else {
            libraryShelves.insert(HomeShelf(title: "Playlists", items: [item]), at: 0)
        }
    }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryFile),
              let state = LocalLibraryPersistence.decode(data) else { return }
        importedTracks = state.importedTracks.filter { track in
            guard let path = track.localPath else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
        localFolders = state.folders
        rebuildLocalTracks()
    }

    private func saveLibrary() {
        let state = LocalLibraryState(importedTracks: importedTracks, folders: localFolders)
        guard let data = LocalLibraryPersistence.encode(state) else { return }
        try? data.write(to: libraryFile, options: .atomic)
    }

    private var importedDirectory: URL {
        libraryFile.deletingLastPathComponent().appendingPathComponent("Imported", isDirectory: true)
    }

    private func rebuildLocalTracks() {
        let indexed = localFolders.flatMap { folderTracks[$0.id] ?? [] }
        localTracks = deduplicatedByPath(importedTracks + indexed)
    }

    private func deduplicatedByPath(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { track in
            guard let path = track.localPath else { return false }
            return seen.insert(URL(fileURLWithPath: path).standardizedFileURL.path).inserted
        }
    }
}
