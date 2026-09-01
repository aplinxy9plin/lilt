import CryptoKit
import Foundation
import os

struct CanvasDownloadedClip: Sendable {
    let temporaryURL: URL
    let responseURL: URL
    let mimeType: String?
    let expectedLength: Int64
}

protocol CanvasClipDownloading: Sendable {
    func download(_ url: URL) async throws -> CanvasDownloadedClip
}

struct URLSessionCanvasClipDownloader: CanvasClipDownloading {
    func download(_ url: URL) async throws -> CanvasDownloadedClip {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let finalURL = response.url else {
            throw URLError(.badServerResponse)
        }
        return CanvasDownloadedClip(
            temporaryURL: temporaryURL,
            responseURL: finalURL,
            mimeType: response.mimeType,
            expectedLength: response.expectedContentLength
        )
    }
}

/// LRU storage for progressive motion artwork. HLS clips use the same root
/// through CanvasHLSResourceLoader, which caches their playlists and media
/// segments while AVPlayer consumes them instead of trying to save a manifest
/// that still points back at the network.
actor CanvasClipCache {
    static let defaultLimitBytes: Int64 = 150 * 1_024 * 1_024
    static let maximumClipBytes: Int64 = 64 * 1_024 * 1_024

    private let directory: URL
    private let limitBytes: Int64
    private let downloader: any CanvasClipDownloading
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private static let logger = Logger(subsystem: "com.bitchord.mac", category: "CanvasCache")

    init(
        directory: URL? = nil,
        limitBytes: Int64 = CanvasClipCache.defaultLimitBytes,
        downloader: any CanvasClipDownloading = URLSessionCanvasClipDownloader()
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.limitBytes = max(1, limitBytes)
        self.downloader = downloader
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord", isDirectory: true)
            .appendingPathComponent("Canvas", isDirectory: true)
    }

    func materialize(_ artwork: CanvasArtwork) async -> CanvasArtwork {
        let primary = await localURL(for: artwork.url)
        var fallback: URL?
        if primary == nil, let fallbackURL = artwork.fallbackURL {
            fallback = await localURL(for: fallbackURL)
        }
        guard primary != nil || fallback != nil else { return artwork }
        return artwork.usingCached(primary: primary, fallback: fallback)
    }

    func cachedURL(for remoteURL: URL) -> URL? {
        let target = targetURL(for: remoteURL)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        touch(target)
        return target
    }

    private func localURL(for remoteURL: URL) async -> URL? {
        // HLS is cached at the resource level while playing. Its manifest by
        // itself is not an offline clip and must never be returned as one.
        guard remoteURL.pathExtension.lowercased() != "m3u8" else { return nil }
        let key = cacheKey(for: remoteURL)
        let target = targetURL(for: remoteURL)
        if FileManager.default.fileExists(atPath: target.path) {
            touch(target)
            return target
        }
        if let task = inFlight[key] { return await task.value }

        let downloader = self.downloader
        let task = Task<URL?, Never> {
            do {
                let clip = try await downloader.download(remoteURL)
                guard Self.isSafeVideoResponse(clip, originalURL: remoteURL),
                      clip.expectedLength <= 0 || clip.expectedLength <= Self.maximumClipBytes else {
                    try? FileManager.default.removeItem(at: clip.temporaryURL)
                    return nil
                }
                let size = Self.recursiveSize(of: clip.temporaryURL)
                guard size > 0, size <= Self.maximumClipBytes else {
                    try? FileManager.default.removeItem(at: clip.temporaryURL)
                    return nil
                }
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: clip.temporaryURL)
                } else {
                    try FileManager.default.moveItem(at: clip.temporaryURL, to: target)
                }
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                return target
            } catch {
                Self.logger.debug(
                    "Canvas clip cache skipped \(remoteURL.pathExtension, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            touch(result)
            Self.prune(directory: directory, limitBytes: limitBytes, excluding: result)
        }
        return result
    }

    private func targetURL(for remoteURL: URL) -> URL {
        let ext = ["mp4", "mov"].contains(remoteURL.pathExtension.lowercased())
            ? remoteURL.pathExtension.lowercased()
            : "mp4"
        return directory.appendingPathComponent("\(cacheKey(for: remoteURL)).\(ext)")
    }

    private func cacheKey(for remoteURL: URL) -> String {
        Self.cacheKey(for: remoteURL)
    }

    static func cacheKey(for remoteURL: URL) -> String {
        SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    static func prune(directory: URL, limitBytes: Int64, excluding protectedURL: URL? = nil) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var rows: [(URL, Date, Int64)] = []
        for case let file as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            rows.append((file, date, recursiveSize(of: file)))
        }
        rows.sort { $0.1 < $1.1 }
        var total = rows.reduce(Int64(0)) { $0 + $1.2 }
        while total > limitBytes, let oldest = rows.first {
            rows.removeFirst()
            guard oldest.0 != protectedURL else { continue }
            if (try? FileManager.default.removeItem(at: oldest.0)) != nil { total -= oldest.2 }
        }
    }

    static func recursiveSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private static func isSafeVideoResponse(
        _ clip: CanvasDownloadedClip,
        originalURL: URL
    ) -> Bool {
        let final = clip.responseURL
        guard final.scheme?.lowercased() == "https", final.host != nil,
              final.user == nil, final.password == nil else { return false }
        let ext = final.pathExtension.lowercased().isEmpty
            ? originalURL.pathExtension.lowercased()
            : final.pathExtension.lowercased()
        return ["mp4", "mov"].contains(ext) || clip.mimeType?.lowercased().hasPrefix("video/") == true
    }
}
