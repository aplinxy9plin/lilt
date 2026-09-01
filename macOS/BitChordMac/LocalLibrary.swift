import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct LocalLibraryFolder: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    let path: String
    let addedAt: Date

    init(url: URL, addedAt: Date = Date()) {
        let standardized = url.standardizedFileURL
        id = standardized.path
        name = standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent
        path = standardized.path
        self.addedAt = addedAt
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

struct LocalMediaCollection: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case artist
        case album
        case folder

        var title: String {
            switch self {
            case .artist: "Artist"
            case .album: "Album"
            case .folder: "Folder"
            }
        }

        var systemImage: String {
            switch self {
            case .artist: "person.fill"
            case .album: "square.stack.fill"
            case .folder: "folder.fill"
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let artworkURL: String?
    let tracks: [Track]
    let folderID: String?
}

struct LocalLibraryState: Codable, Sendable {
    var version = 2
    var importedTracks: [Track]
    var folders: [LocalLibraryFolder]
}

enum LocalLibraryPersistence {
    static func decode(_ data: Data) -> LocalLibraryState? {
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(LocalLibraryState.self, from: data) {
            return state
        }
        if let legacy = try? decoder.decode([Track].self, from: data) {
            return LocalLibraryState(importedTracks: legacy, folders: [])
        }
        return nil
    }

    static func encode(_ state: LocalLibraryState) -> Data? {
        try? JSONEncoder().encode(state)
    }
}

struct LocalMediaIndexer: Sendable {
    static let maximumFilesPerFolder = 20_000
    static let maximumArtworkBytes = 12 * 1_024 * 1_024

    private static let supportedExtensions: Set<String> = [
        "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "m4b", "mka",
        "mp3", "mp4", "ogg", "opus", "wav", "wave", "webm", "3gp"
    ]

    let artworkDirectory: URL

    init(artworkDirectory: URL) {
        self.artworkDirectory = artworkDirectory
    }

    func tracks(in folder: LocalLibraryFolder) async -> [Track] {
        let urls = await Task.detached(priority: .utility) {
            Self.audioFiles(in: folder.url)
        }.value
        guard !urls.isEmpty else { return [] }

        var indexed: [(Int, Track)] = []
        indexed.reserveCapacity(urls.count)
        let batchSize = 8
        for batchStart in stride(from: 0, to: urls.count, by: batchSize) {
            guard !Task.isCancelled else { return [] }
            let batchEnd = min(batchStart + batchSize, urls.count)
            let batch = Array(urls[batchStart..<batchEnd])
            let values = await withTaskGroup(of: (Int, Track?).self, returning: [(Int, Track)].self) { group in
                for (offset, url) in batch.enumerated() {
                    group.addTask {
                        let track = await track(at: url, folderID: folder.id)
                        return (batchStart + offset, track)
                    }
                }
                var result: [(Int, Track)] = []
                for await (index, track) in group {
                    if let track { result.append((index, track)) }
                }
                return result
            }
            indexed.append(contentsOf: values)
        }
        return indexed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func refreshedTrack(_ existing: Track) async -> Track? {
        guard let path = existing.localPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let refreshed = await track(at: url, folderID: existing.localFolderID) else { return existing }
        return Track(
            videoID: existing.videoID,
            title: refreshed.title,
            artist: refreshed.artist,
            album: refreshed.album,
            artworkURL: refreshed.artworkURL ?? existing.artworkURL,
            duration: refreshed.duration ?? existing.duration,
            localPath: refreshed.localPath,
            sourceURL: existing.sourceURL,
            setVideoID: existing.setVideoID,
            localFolderID: existing.localFolderID
        )
    }

    func track(at url: URL, folderID: String?) async -> Track? {
        let artworkDirectory = self.artworkDirectory
        return await Task.detached(priority: .utility) {
            await Self.readTrack(at: url, folderID: folderID, artworkDirectory: artworkDirectory)
        }.value
    }

    static func isSupportedAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if supportedExtensions.contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .audio) == true
    }

    private static func audioFiles(in root: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        result.reserveCapacity(512)
        for case let url as URL in enumerator {
            guard result.count < maximumFilesPerFolder else { break }
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, values?.isHidden != true,
                  isSupportedAudioFile(url) else { continue }
            result.append(url.standardizedFileURL)
        }
        return result.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func readTrack(
        at url: URL,
        folderID: String?,
        artworkDirectory: URL
    ) async -> Track? {
        guard FileManager.default.fileExists(atPath: url.path), isSupportedAudioFile(url) else { return nil }
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let durationValue = try? await asset.load(.duration)
        let seconds = durationValue?.seconds
        let duration = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? audioFileDuration(at: url)

        let title = await text(for: .commonKeyTitle, in: metadata)
            ?? url.deletingPathExtension().lastPathComponent
        let artistName = await text(for: .commonKeyArtist, in: metadata)
        let creator = await text(for: .commonKeyCreator, in: metadata)
        let artist = artistName ?? creator ?? "Unknown Artist"
        let album = await text(for: .commonKeyAlbumName, in: metadata)
        let embeddedArtwork = await artwork(in: metadata)
        let artwork = embeddedArtwork ?? siblingArtwork(near: url)
        let artworkURL = artwork.flatMap {
            cachedArtworkURL(for: $0, directory: artworkDirectory)?.absoluteString
        }

        return Track(
            videoID: nil,
            title: clean(title) ?? url.deletingPathExtension().lastPathComponent,
            artist: clean(artist) ?? "Unknown Artist",
            album: clean(album),
            artworkURL: artworkURL,
            duration: duration,
            localPath: url.standardizedFileURL.path,
            sourceURL: nil,
            localFolderID: folderID
        )
    }

    private static func text(for key: AVMetadataKey, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = metadata.first(where: { $0.commonKey?.rawValue == key.rawValue }) else { return nil }
        return clean(try? await item.load(.stringValue))
    }

    private static func artwork(in metadata: [AVMetadataItem]) async -> Data? {
        guard let item = metadata.first(where: {
            $0.commonKey?.rawValue == AVMetadataKey.commonKeyArtwork.rawValue
        }), let data = try? await item.load(.dataValue),
              !data.isEmpty, data.count <= maximumArtworkBytes else { return nil }
        return data
    }

    private static func siblingArtwork(near audioURL: URL) -> Data? {
        let directory = audioURL.deletingLastPathComponent()
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let preferredNames = ["cover", "folder", "front", "album", "artwork"]
        let images = candidates.filter {
            ["jpg", "jpeg", "png", "webp", "heic"].contains($0.pathExtension.lowercased())
        }
        guard let match = preferredNames.compactMap({ preferred in
            images.first { $0.deletingPathExtension().lastPathComponent.lowercased() == preferred }
        }).first ?? images.first else { return nil }
        guard let size = try? match.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumArtworkBytes else { return nil }
        return try? Data(contentsOf: match, options: .mappedIfSafe)
    }

    private static func cachedArtworkURL(for data: Data, directory: URL) -> URL? {
        guard !data.isEmpty, data.count <= maximumArtworkBytes else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent(digest).appendingPathExtension("image")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }

    private static func audioFileDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }

    private static func clean(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleaned, !cleaned.isEmpty, cleaned.caseInsensitiveCompare("<unknown>") != .orderedSame else {
            return nil
        }
        return cleaned
    }
}

enum LocalLibraryOrganizer {
    static func collections(
        kind: LocalMediaCollection.Kind,
        tracks: [Track],
        folders: [LocalLibraryFolder]
    ) -> [LocalMediaCollection] {
        switch kind {
        case .artist:
            return grouped(
                tracks: tracks,
                kind: kind,
                value: { $0.artist.isEmpty ? "Unknown Artist" : $0.artist },
                subtitle: { tracks in
                    let albums = Set(tracks.compactMap(\.album)).count
                    return albums > 0 ? "\(albums) \(albums == 1 ? "album" : "albums") · \(songCount(tracks.count))" : songCount(tracks.count)
                }
            )
        case .album:
            return grouped(
                tracks: tracks.filter { $0.album?.isEmpty == false },
                kind: kind,
                value: { $0.album ?? "Unknown Album" },
                subtitle: { tracks in
                    let artists = tracks.map(\.artist).uniquedLocal()
                    let credit = artists.count == 1 ? artists[0] : "Various Artists"
                    return "\(credit) · \(songCount(tracks.count))"
                }
            )
        case .folder:
            let byFolder = Dictionary(grouping: tracks.compactMap { track -> Track? in
                track.localFolderID == nil ? nil : track
            }, by: { $0.localFolderID ?? "" })
            return folders.map { folder in
                let rows = sorted(byFolder[folder.id] ?? [])
                return LocalMediaCollection(
                    id: "folder:\(folder.id)",
                    kind: .folder,
                    title: folder.name,
                    subtitle: songCount(rows.count),
                    artworkURL: rows.compactMap(\.artworkURL).first,
                    tracks: rows,
                    folderID: folder.id
                )
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    static func filtered(_ tracks: [Track], query: String) -> [Track] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sorted(tracks) }
        return sorted(tracks.filter {
            $0.title.localizedCaseInsensitiveContains(needle) ||
                $0.artist.localizedCaseInsensitiveContains(needle) ||
                ($0.album?.localizedCaseInsensitiveContains(needle) == true)
        })
    }

    private static func grouped(
        tracks: [Track],
        kind: LocalMediaCollection.Kind,
        value: (Track) -> String,
        subtitle: ([Track]) -> String
    ) -> [LocalMediaCollection] {
        let rows = Dictionary(grouping: tracks) {
            value($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        return rows.values.compactMap { group in
            guard let first = group.first else { return nil }
            let ordered = sorted(group)
            let title = value(first)
            return LocalMediaCollection(
                id: "\(kind.rawValue):\(title.lowercased())",
                kind: kind,
                title: title,
                subtitle: subtitle(ordered),
                artworkURL: ordered.compactMap(\.artworkURL).first,
                tracks: ordered,
                folderID: nil
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func sorted(_ tracks: [Track]) -> [Track] {
        tracks.sorted {
            let leftAlbum = $0.album ?? ""
            let rightAlbum = $1.album ?? ""
            if leftAlbum.localizedCaseInsensitiveCompare(rightAlbum) != .orderedSame {
                return leftAlbum.localizedCaseInsensitiveCompare(rightAlbum) == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func songCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "song" : "songs")"
    }
}

private extension Array where Element == String {
    func uniquedLocal() -> [String] {
        var seen = Set<String>()
        return filter {
            seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted
        }
    }
}
