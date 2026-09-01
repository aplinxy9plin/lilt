import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case home
    case explore
    case search
    case library
    case downloads
    case replay
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .explore: "Explore"
        case .search: "Search"
        case .library: "Library"
        case .downloads: "Downloads"
        case .replay: "Replay"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .explore: "safari.fill"
        case .search: "magnifyingglass"
        case .library: "rectangle.stack.fill"
        case .downloads: "arrow.down.circle.fill"
        case .replay: "sparkles"
        case .settings: "gearshape.fill"
        }
    }
}

enum AudioQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var detail: String {
        switch self {
        case .low: "~64 kbps · smallest data use"
        case .medium: "~128 kbps · balanced"
        case .high: "Best compatible stream"
        }
    }

    var hourlyEstimate: String {
        switch self {
        case .low: "29 MB/hr"
        case .medium: "58 MB/hr"
        case .high: "77 MB/hr"
        }
    }

    /// YouTube's nominal 128 kbps AAC stream is commonly reported around
    /// 129–130 kbps once container overhead is included.
    var selectionCeilingKbps: Double {
        switch self {
        case .low: 64
        case .medium: 132
        case .high: .greatestFiniteMagnitude
        }
    }

    var systemImage: String {
        switch self {
        case .low: "leaf.fill"
        case .medium: "waveform"
        case .high: "sparkles"
        }
    }
}

struct AudioStreamInfo: Equatable, Sendable {
    let requestedQuality: AudioQuality
    let bitrateKbps: Int?
    let codec: String?
    let sampleRate: Int?
    let channels: Int?
    let bitDepth: Int?
    let sourceName: String?

    init(
        requestedQuality: AudioQuality,
        bitrateKbps: Int?,
        codec: String?,
        sampleRate: Int?,
        channels: Int?,
        bitDepth: Int? = nil,
        sourceName: String? = nil
    ) {
        self.requestedQuality = requestedQuality
        self.bitrateKbps = bitrateKbps
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.sourceName = sourceName
    }

    var isLossless: Bool {
        guard let codec = codec?.lowercased() else { return false }
        return ["flac", "alac", "wav", "aiff", "pcm", "lpcm", "ape", "wv", "dsf", "dff"].contains(codec)
    }

    func isMeaningfullyBetter(than other: AudioStreamInfo?) -> Bool {
        guard let other else { return true }
        if isLossless != other.isLossless { return isLossless }
        if let bitDepth, let otherDepth = other.bitDepth, bitDepth != otherDepth {
            return bitDepth > otherDepth
        }
        if let sampleRate, let otherRate = other.sampleRate, sampleRate != otherRate {
            return sampleRate > otherRate
        }
        return (bitrateKbps ?? 0) >= (other.bitrateKbps ?? 0) + 96
    }

    var shortDescription: String {
        var components = [sourceName ?? requestedQuality.title]
        if isLossless { components.append("Lossless") }
        if let bitDepth { components.append("\(bitDepth)-bit") }
        if let bitrateKbps { components.append("\(bitrateKbps) kbps") }
        if let codec, !codec.isEmpty { components.append(codec) }
        return components.joined(separator: " · ")
    }

    /// Mirrors Android's Stats for Nerds line: only values reported by the
    /// active decoder/stream are shown, and bitrate is intentionally omitted
    /// for lossless codecs where it is not a useful quality comparison.
    var technicalDescription: String? {
        var components: [String] = []
        if let codec = displayCodec { components.append(codec) }
        if let bitDepth, bitDepth > 0 { components.append("\(bitDepth)-bit") }
        if !isLossless, let bitrateKbps, bitrateKbps > 0 {
            components.append("\(bitrateKbps) kbps")
        }
        if let sampleRate, sampleRate > 0 {
            components.append(String(format: "%.1f kHz", Double(sampleRate) / 1_000))
        }
        if let channels, channels > 0 {
            switch channels {
            case 1: components.append("Mono")
            case 2: components.append("Stereo")
            default: components.append("\(channels) ch")
            }
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private var displayCodec: String? {
        guard let raw = codec?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lowered = raw.lowercased()
        if lowered.contains("opus") { return "Opus" }
        if lowered.contains("mp4a") || lowered == "aac" || lowered.contains("aac-") { return "AAC" }
        if lowered.contains("vorbis") { return "Vorbis" }
        if lowered == "mpeg" || lowered == "mp3" || lowered.contains("audio/mpeg") { return "MP3" }
        if lowered.contains("flac") { return "FLAC" }
        if lowered.contains("alac") { return "ALAC" }
        return raw.uppercased()
    }
}

enum SearchFilter: String, CaseIterable, Identifiable {
    case songs
    case albums
    case artists
    case playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .playlists: "Playlists"
        }
    }

    var apiParameter: String? {
        switch self {
        case .songs: "EgWKAQIIAWoKEAkQChAFEAMQBA=="
        case .albums: "EgWKAQIYAWoKEAkQChAFEAMQBA=="
        case .artists: "EgWKAQIgAWoKEAkQChAFEAMQBA=="
        case .playlists: "EgWKAQIoAWoKEAkQChAFEAMQBA=="
        }
    }
}

/// A non-YouTube catalogue that issued a track row. Keeping this identity on
/// the track lets search results return to the same source at playback and
/// download time instead of pretending every remote id belongs to YouTube.
enum TrackCatalogSource: String, Codable, Sendable {
    case jioSaavn

    var title: String {
        switch self {
        case .jioSaavn: "JioSaavn"
        }
    }
}

struct Track: Identifiable, Hashable, Codable, Sendable {
    let videoID: String?
    var title: String
    var artist: String
    var album: String?
    var artworkURL: String?
    var duration: TimeInterval?
    var localPath: String?
    var sourceURL: String?
    /// YouTube Music browse destinations carried by artist/album credit runs.
    /// Optional fields keep older local-library and download JSON decodable.
    var artistBrowseID: String? = nil
    var albumBrowseID: String? = nil
    var setVideoID: String? = nil
    var localFolderID: String? = nil
    /// Queue-only provenance. Optional keeps older persisted library JSON
    /// decodable while letting AutoPlay entries survive normal queue copies.
    var fromAutoplay: Bool? = nil
    /// True when YouTube Music presented this row as a music-video upload.
    /// Optional keeps queues, downloads and Replay records written by older
    /// macOS builds decodable; nil is treated as an ordinary catalogue track.
    var isVideo: Bool? = nil
    /// Identity issued by a catalogue other than YouTube Music.
    var catalogSource: TrackCatalogSource? = nil
    var catalogTrackID: String? = nil

    var id: String {
        if let localPath { return "local:\(localPath)" }
        if let catalogSource, let catalogTrackID {
            return "\(catalogSource.rawValue):\(catalogTrackID)"
        }
        if let videoID { return "youtube:\(videoID)" }
        return "track:\(title)-\(artist)"
    }

    var isLocal: Bool { localPath != nil }
    var isFromAutoplay: Bool { fromAutoplay == true }
    var isMusicVideo: Bool { isVideo == true }
    var hasRemotePlaybackSource: Bool { videoID != nil || (catalogSource != nil && catalogTrackID != nil) }

    /// Stable on-disk identity. YouTube keeps its historical bare video id so
    /// existing download metadata remains compatible; other catalogues carry
    /// their namespace to prevent collisions.
    var downloadIdentifier: String? {
        if let catalogSource, let catalogTrackID {
            return "\(catalogSource.rawValue):\(catalogTrackID)"
        }
        return videoID
    }

    var durationText: String {
        guard let duration, duration.isFinite, duration > 0 else { return "" }
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    var youtubeURL: URL? {
        guard catalogSource == nil, let videoID else { return nil }
        return URL(string: "https://music.youtube.com/watch?v=\(videoID)")
    }

    func mergingBrowseLinks(from other: Track) -> Track {
        var merged = self
        if merged.artistBrowseID == nil { merged.artistBrowseID = other.artistBrowseID }
        if merged.albumBrowseID == nil { merged.albumBrowseID = other.albumBrowseID }
        if merged.album == nil || merged.album?.isEmpty == true { merged.album = other.album }
        return merged
    }
}

enum LikeStatus: String, Codable, CaseIterable, Sendable {
    case like = "LIKE"
    case dislike = "DISLIKE"
    case indifferent = "INDIFFERENT"
}

enum PlaylistPrivacy: String, Codable, CaseIterable, Identifiable, Sendable {
    case privatePlaylist = "PRIVATE"
    case unlisted = "UNLISTED"
    case publicPlaylist = "PUBLIC"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privatePlaylist: "Private"
        case .unlisted: "Unlisted"
        case .publicPlaylist: "Public"
        }
    }

    var systemImage: String {
        switch self {
        case .privatePlaylist: "lock.fill"
        case .unlisted: "link"
        case .publicPlaylist: "globe"
        }
    }
}

struct UserPlaylist: Identifiable, Hashable, Sendable {
    let playlistID: String
    var title: String
    var subtitle: String
    var artworkURL: String?

    var id: String { playlistID }
    var browseID: String { "VL\(playlistID)" }
}

struct BrowseItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case album
        case artist
        case playlist
        case other
    }

    let id: String
    let title: String
    let subtitle: String
    let artworkURL: String?
    let kind: Kind
}

struct BrowsePage: Sendable {
    let item: BrowseItem
    let tracks: [Track]
}

enum SearchResult: Identifiable, Hashable, Sendable {
    case track(Track)
    case browse(BrowseItem)

    var id: String {
        switch self {
        case .track(let track): "track:\(track.id)"
        case .browse(let item): "browse:\(item.id)"
        }
    }
}

struct ShelfItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let artworkURL: String?
    let track: Track?
    let browseItem: BrowseItem?

    init(title: String, subtitle: String, artworkURL: String?, track: Track? = nil, browseItem: BrowseItem? = nil) {
        self.id = track?.id ?? browseItem?.id ?? "shelf:\(title):\(subtitle)"
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.track = track
        self.browseItem = browseItem
    }
}

struct HomeShelf: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let items: [ShelfItem]

    init(title: String, subtitle: String = "", items: [ShelfItem]) {
        self.id = "shelf:\(title)"
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }
}

struct LyricWord: Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct LyricBackground: Hashable, Sendable {
    let start: TimeInterval
    let text: String
    let end: TimeInterval?
    let words: [LyricWord]

    init(start: TimeInterval, text: String, end: TimeInterval? = nil, words: [LyricWord] = []) {
        self.start = start
        self.text = text
        self.end = end
        self.words = words
    }

    var isWordSynced: Bool { !words.isEmpty }
    var sungUntil: TimeInterval { words.last?.end ?? end ?? start }

    func revealedCharacterCount(at position: TimeInterval) -> Double {
        lyricRevealedCharacterCount(text: text, words: words, start: start, at: position)
    }
}

struct LyricLine: Identifiable, Hashable, Sendable {
    let id: Int
    let start: TimeInterval
    let text: String
    let end: TimeInterval?
    let words: [LyricWord]
    let background: LyricBackground?

    init(
        id: Int? = nil,
        start: TimeInterval,
        text: String,
        end: TimeInterval? = nil,
        words: [LyricWord] = [],
        background: LyricBackground? = nil
    ) {
        self.id = id ?? Int((start * 1_000).rounded())
        self.start = start
        self.text = text
        self.end = end
        self.words = words
        self.background = background
    }

    var isGap: Bool { text.isEmpty }
    var isWordSynced: Bool { !words.isEmpty }
    var hasKnownEnd: Bool { !words.isEmpty || end != nil }

    var sungUntil: TimeInterval {
        let lead = words.last?.end ?? end ?? start
        return max(lead, background?.sungUntil ?? lead)
    }

    /// Fractional character position reached by the active word. This mirrors
    /// the Android lyric sweep while still allowing SwiftUI to wrap the line.
    func revealedCharacterCount(at position: TimeInterval) -> Double {
        lyricRevealedCharacterCount(text: text, words: words, start: start, at: position)
    }
}

private func lyricRevealedCharacterCount(
    text: String,
    words: [LyricWord],
    start: TimeInterval,
    at position: TimeInterval
) -> Double {
        guard !words.isEmpty else { return position >= start ? Double(text.count) : 0 }
        var searchOffset = text.startIndex
        for (index, word) in words.enumerated() {
            let range = text.range(of: word.text, range: searchOffset..<text.endIndex)
            let wordStart = range?.lowerBound ?? searchOffset
            let wordEnd = range?.upperBound ?? wordStart
            let leadingCharacters = text.distance(from: text.startIndex, to: wordStart)
            let throughWordCharacters = text.distance(from: wordStart, to: wordEnd)

            if position < word.start { return Double(leadingCharacters) }
            if position < word.end {
                let span = max(0.001, word.end - word.start)
                let progress = max(0, min(1, (position - word.start) / span))
                return Double(leadingCharacters) + progress * Double(throughWordCharacters)
            }

            if let next = words[safe: index + 1], position < next.start {
                let nextRange = text.range(of: next.text, range: wordEnd..<text.endIndex)
                let nextStart = nextRange?.lowerBound ?? wordEnd
                let endCharacters = text.distance(from: text.startIndex, to: wordEnd)
                let gapCharacters = text.distance(from: wordEnd, to: nextStart)
                let pause = max(0.001, next.start - word.end)
                let progress = max(0, min(1, (position - word.end) / pause))
                return Double(endCharacters) + progress * Double(gapCharacters)
            }
            searchOffset = wordEnd
        }
        return Double(text.count)
}

struct Lyrics: Sendable {
    let lines: [LyricLine]
    let source: String
    let isWordSynced: Bool

    init(lines: [LyricLine], source: String, isWordSynced: Bool? = nil) {
        self.lines = lines
        self.source = source
        self.isWordSynced = isWordSynced ?? lines.contains(where: \.isWordSynced)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
