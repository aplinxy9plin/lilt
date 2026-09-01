import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// AVPlayer resource loader that turns an HLS Canvas into a read-through disk
/// cache. Playlists are rewritten to the private scheme, so absolute segment
/// URLs are intercepted too; every later loop is served from the same bounded
/// cache instead of downloading the segment again.
final class CanvasHLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "bitchord-canvas"

    private let directory: URL
    private let queue = DispatchQueue(label: "com.bitchord.mac.canvas-hls")
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(directory: URL = CanvasClipCache.defaultDirectory.appendingPathComponent("HLS", isDirectory: true)) {
        self.directory = directory
        super.init()
    }

    func asset(for remoteURL: URL) -> AVURLAsset? {
        guard let proxy = Self.proxyURL(for: remoteURL) else { return nil }
        let asset = AVURLAsset(url: proxy)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let proxyURL = loadingRequest.request.url,
              let remoteURL = Self.remoteURL(for: proxyURL) else { return false }
        let key = ObjectIdentifier(loadingRequest)
        if let cached = try? Data(contentsOf: cacheURL(for: remoteURL)), !cached.isEmpty {
            touch(cacheURL(for: remoteURL))
            Self.finish(loadingRequest, data: cached, remoteURL: remoteURL, mimeType: nil)
            return true
        }

        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(CanvasUserAgent.browser, forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.dataTask(with: request) { [weak self, weak loadingRequest] data, response, error in
            guard let self, let loadingRequest else { return }
            queue.async {
                self.tasks[key] = nil
                guard error == nil,
                      let data,
                      !data.isEmpty,
                      data.count <= CanvasClipCache.maximumClipBytes,
                      let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let finalURL = response.url,
                      finalURL.scheme?.lowercased() == "https",
                      finalURL.host != nil,
                      finalURL.user == nil,
                      finalURL.password == nil else {
                    loadingRequest.finishLoading(with: error ?? URLError(.badServerResponse))
                    return
                }
                let body = Self.isPlaylist(remoteURL: remoteURL, mimeType: response.mimeType)
                    ? Self.rewritePlaylist(data)
                    : data
                let target = self.cacheURL(for: remoteURL)
                do {
                    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                    try body.write(to: target, options: .atomic)
                    self.touch(target)
                    CanvasClipCache.prune(
                        directory: CanvasClipCache.defaultDirectory,
                        limitBytes: CanvasClipCache.defaultLimitBytes,
                        excluding: target
                    )
                } catch {
                    // Cache failure must never make the visible Canvas fail.
                }
                Self.finish(
                    loadingRequest,
                    data: body,
                    remoteURL: remoteURL,
                    mimeType: response.mimeType
                )
            }
        }
        tasks[key] = task
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        tasks.removeValue(forKey: key)?.cancel()
    }

    private func cacheURL(for remoteURL: URL) -> URL {
        let sourceExtension = remoteURL.pathExtension.lowercased()
        let ext = sourceExtension.isEmpty || sourceExtension.count > 8 ? "bin" : sourceExtension
        return directory.appendingPathComponent("\(CanvasClipCache.cacheKey(for: remoteURL)).\(ext)")
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func proxyURL(for remoteURL: URL) -> URL? {
        guard remoteURL.scheme?.lowercased() == "https", remoteURL.host != nil,
              remoteURL.user == nil, remoteURL.password == nil,
              var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        return components.url
    }

    static func remoteURL(for proxyURL: URL) -> URL? {
        guard proxyURL.scheme == scheme,
              var components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        guard let url = components.url, url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func rewritePlaylist(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(pattern: #"https://[^\"'\s]+"#) else { return data }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text),
                  let remote = URL(string: String(text[range])),
                  let proxy = proxyURL(for: remote) else { continue }
            text.replaceSubrange(range, with: proxy.absoluteString)
        }
        return Data(text.utf8)
    }

    static func requestedData(_ data: Data, for request: AVAssetResourceLoadingDataRequest) -> Data? {
        let offset = max(request.requestedOffset, request.currentOffset)
        guard offset >= 0, offset < Int64(data.count) else { return nil }
        let start = Int(offset)
        let end = request.requestsAllDataToEndOfResource
            ? data.count
            : min(data.count, start + request.requestedLength)
        guard start < end else { return nil }
        return data.subdata(in: start..<end)
    }

    private static func finish(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        data: Data,
        remoteURL: URL,
        mimeType: String?
    ) {
        if let information = loadingRequest.contentInformationRequest {
            let looksLikePlaylist = remoteURL.pathExtension.lowercased() == "m3u8" ||
                String(data: data.prefix(16), encoding: .utf8)?.hasPrefix("#EXTM3U") == true
            let resolvedMime = mimeType ?? (looksLikePlaylist
                ? "application/vnd.apple.mpegurl"
                : "application/octet-stream")
            information.contentType = UTType(mimeType: resolvedMime)?.identifier
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest,
              let requested = requestedData(data, for: dataRequest) else {
            loadingRequest.finishLoading(with: URLError(.cannotDecodeContentData))
            return
        }
        dataRequest.respond(with: requested)
        loadingRequest.finishLoading()
    }

    private static func isPlaylist(remoteURL: URL, mimeType: String?) -> Bool {
        remoteURL.pathExtension.lowercased() == "m3u8" ||
            mimeType?.lowercased().contains("mpegurl") == true
    }
}
