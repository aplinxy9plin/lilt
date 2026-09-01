import Combine
import Foundation

enum ReplayPeriod: String, CaseIterable, Identifiable, Sendable {
    case thisMonth
    case thisYear
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisMonth: "This month"
        case .thisYear: "This year"
        case .allTime: "All time"
        }
    }
}

struct ReplayTrackStat: Identifiable, Equatable, Sendable {
    let track: Track
    let milliseconds: Int64
    let plays: Int

    var id: String { track.id }
}

struct ReplayNamedStat: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let artworkURL: String?
    let milliseconds: Int64
    let plays: Int
}

struct ReplaySummary: Equatable, Sendable {
    let period: ReplayPeriod
    let totalMilliseconds: Int64
    let totalPlays: Int
    let tracks: [ReplayTrackStat]
    let artists: [ReplayNamedStat]
    let albums: [ReplayNamedStat]
    let genres: [ReplayNamedStat]
    let busiestHour: Int?
    let busiestHourMilliseconds: Int64
    let busiestDay: String?
    let busiestDayMilliseconds: Int64
    let memberSince: Date?

    static func empty(_ period: ReplayPeriod) -> ReplaySummary {
        ReplaySummary(
            period: period,
            totalMilliseconds: 0,
            totalPlays: 0,
            tracks: [],
            artists: [],
            albums: [],
            genres: [],
            busiestHour: nil,
            busiestHourMilliseconds: 0,
            busiestDay: nil,
            busiestDayMilliseconds: 0,
            memberSince: nil
        )
    }

    var distinctSongs: Int { tracks.count }
    var distinctArtists: Int { artists.count }
    var totalMinutes: Int { Int(totalMilliseconds / 60_000) }
    var isEmpty: Bool { totalMilliseconds == 0 && totalPlays == 0 }
}

struct StoredListeningTrack: Codable, Sendable {
    var track: Track
    var milliseconds: Int64
    var plays: Int
    var lastPlayedAt: Date
}

struct StoredListeningBucket: Codable, Sendable {
    var month: String
    var tracks: [String: StoredListeningTrack]
    var hours: [Int64]
    var days: [String: Int64]

    init(month: String) {
        self.month = month
        tracks = [:]
        hours = Array(repeating: 0, count: 24)
        days = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case month, tracks, hours, days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        month = try container.decodeIfPresent(String.self, forKey: .month) ?? ""
        tracks = try container.decodeIfPresent([String: StoredListeningTrack].self, forKey: .tracks) ?? [:]
        hours = try container.decodeIfPresent([Int64].self, forKey: .hours) ?? []
        if hours.count < 24 {
            hours.append(contentsOf: repeatElement(0, count: 24 - hours.count))
        } else if hours.count > 24 {
            hours = Array(hours.prefix(24))
        }
        days = try container.decodeIfPresent([String: Int64].self, forKey: .days) ?? [:]
    }
}

/// Bounded local listening history. Like the Android implementation it stores
/// one aggregate JSON file per calendar month instead of an ever-growing event
/// log. Nothing is uploaded and no account identifier is written to disk.
actor ListeningStatsStore {
    private let directory: URL
    private let calendar: Calendar
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var loaded: [String: StoredListeningBucket] = [:]
    private var dirtyKeys = Set<String>()
    private var delayedFlush: Task<Void, Never>?

    init(directory: URL? = nil, calendar: Calendar = .current) {
        if let directory {
            self.directory = directory
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BitChord", isDirectory: true)
            self.directory = root.appendingPathComponent("ListeningStats", isDirectory: true)
        }
        self.calendar = calendar
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    deinit {
        delayedFlush?.cancel()
    }

    func record(
        track: Track,
        playedSeconds: TimeInterval,
        countsAsPlay: Bool,
        at date: Date = Date()
    ) {
        let milliseconds = Int64(max(0, playedSeconds) * 1_000)
        guard milliseconds > 0 || countsAsPlay else { return }
        let key = Self.monthKey(for: date, calendar: calendar)
        var bucket = bucket(for: key)
        var entry = bucket.tracks[track.id] ?? StoredListeningTrack(
            track: track,
            milliseconds: 0,
            plays: 0,
            lastPlayedAt: date
        )
        entry.track = mergedMetadata(old: entry.track, new: track)
        entry.milliseconds += milliseconds
        if countsAsPlay { entry.plays += 1 }
        entry.lastPlayedAt = max(entry.lastPlayedAt, date)
        bucket.tracks[track.id] = entry

        let hour = calendar.component(.hour, from: date)
        if bucket.hours.indices.contains(hour) { bucket.hours[hour] += milliseconds }
        let day = Self.dayKey(for: date, calendar: calendar)
        bucket.days[day, default: 0] += milliseconds
        loaded[key] = bucket
        dirtyKeys.insert(key)
        scheduleFlush()
    }

    func flush() {
        delayedFlush?.cancel()
        delayedFlush = nil
        guard !dirtyKeys.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys = dirtyKeys
        for key in keys {
            guard let bucket = loaded[key],
                  let data = try? encoder.encode(bucket) else { continue }
            let target = directory.appendingPathComponent("\(key).json")
            do {
                try data.write(to: target, options: .atomic)
                dirtyKeys.remove(key)
            } catch {
                // Keep the key dirty so a later stop/refresh retries it.
            }
        }
    }

    /// Every persisted month, for a user-owned backup. Pending actor writes are
    /// flushed first so the exported JSON is a coherent snapshot.
    func exportAll() -> [StoredListeningBucket] {
        flush()
        return availableKeys().sorted().map(bucket(for:))
    }

    /// Replaces Replay data as one transaction. All buckets are validated and
    /// encoded into a staging directory before the live directory is touched;
    /// if the swap fails, the previous directory is restored.
    func replaceAll(with buckets: [StoredListeningBucket]) throws {
        delayedFlush?.cancel()
        delayedFlush = nil

        var seen = Set<String>()
        let prepared = try buckets.map { bucket -> (String, Data) in
            guard Self.isMonthKey(bucket.month), seen.insert(bucket.month).inserted else {
                throw ListeningStatsBackupError.invalidMonth(bucket.month)
            }
            guard bucket.hours.count == 24,
                  bucket.hours.allSatisfy({ $0 >= 0 }),
                  bucket.days.values.allSatisfy({ $0 >= 0 }),
                  bucket.tracks.values.allSatisfy({ $0.milliseconds >= 0 && $0.plays >= 0 }) else {
                throw ListeningStatsBackupError.invalidBucket(bucket.month)
            }
            return (bucket.month, try encoder.encode(bucket))
        }

        let fileManager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".ListeningStats-import-\(UUID().uuidString)", isDirectory: true)
        let previous = parent.appendingPathComponent(".ListeningStats-previous-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            for (month, data) in prepared {
                try data.write(to: staging.appendingPathComponent("\(month).json"), options: .atomic)
            }
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.moveItem(at: directory, to: previous)
            }
            do {
                try fileManager.moveItem(at: staging, to: directory)
                if fileManager.fileExists(atPath: previous.path) {
                    try? fileManager.removeItem(at: previous)
                }
            } catch {
                if fileManager.fileExists(atPath: previous.path) {
                    try? fileManager.moveItem(at: previous, to: directory)
                }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        loaded = Dictionary(uniqueKeysWithValues: buckets.map { ($0.month, $0) })
        dirtyKeys.removeAll()
    }

    func summary(for period: ReplayPeriod, now: Date = Date()) -> ReplaySummary {
        let keys = availableKeys().filter { key in
            switch period {
            case .thisMonth:
                return key == Self.monthKey(for: now, calendar: calendar)
            case .thisYear:
                let year = calendar.component(.year, from: now)
                return key.hasPrefix(String(format: "%04d-", year))
            case .allTime:
                return true
            }
        }

        var mergedTracks: [String: StoredListeningTrack] = [:]
        var hours = Array(repeating: Int64(0), count: 24)
        var days: [String: Int64] = [:]
        var memberSince: Date?

        for key in keys.sorted() {
            let bucket = bucket(for: key)
            for (id, incoming) in bucket.tracks {
                if var current = mergedTracks[id] {
                    current.milliseconds += incoming.milliseconds
                    current.plays += incoming.plays
                    if incoming.lastPlayedAt >= current.lastPlayedAt {
                        current.track = mergedMetadata(old: current.track, new: incoming.track)
                        current.lastPlayedAt = incoming.lastPlayedAt
                    }
                    mergedTracks[id] = current
                } else {
                    mergedTracks[id] = incoming
                }
                memberSince = min(memberSince ?? incoming.lastPlayedAt, incoming.lastPlayedAt)
            }
            for index in hours.indices where bucket.hours.indices.contains(index) {
                hours[index] += bucket.hours[index]
            }
            for (day, value) in bucket.days { days[day, default: 0] += value }
        }

        let trackRows = mergedTracks.values
            .map { ReplayTrackStat(track: $0.track, milliseconds: $0.milliseconds, plays: $0.plays) }
            .sorted(by: Self.ranked)

        var artistRows: [String: ReplayNamedStat] = [:]
        var albumRows: [String: ReplayNamedStat] = [:]
        for row in trackRows {
            let artist = Self.primaryArtist(row.track.artist)
            if !artist.isEmpty {
                let key = artist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                let current = artistRows[key]
                artistRows[key] = ReplayNamedStat(
                    id: key,
                    title: current?.title ?? artist,
                    subtitle: nil,
                    artworkURL: current?.artworkURL ?? row.track.artworkURL,
                    milliseconds: (current?.milliseconds ?? 0) + row.milliseconds,
                    plays: (current?.plays ?? 0) + row.plays
                )
            }
            if let album = row.track.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
                let key = "\(album)|\(artist)".folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                let current = albumRows[key]
                albumRows[key] = ReplayNamedStat(
                    id: key,
                    title: current?.title ?? album,
                    subtitle: current?.subtitle ?? artist,
                    artworkURL: current?.artworkURL ?? row.track.artworkURL,
                    milliseconds: (current?.milliseconds ?? 0) + row.milliseconds,
                    plays: (current?.plays ?? 0) + row.plays
                )
            }
        }

        let busiestHour = hours.enumerated().max { lhs, rhs in lhs.element < rhs.element }
        let busiestDay = days.max { lhs, rhs in lhs.value < rhs.value }
        return ReplaySummary(
            period: period,
            totalMilliseconds: trackRows.reduce(0) { $0 + $1.milliseconds },
            totalPlays: trackRows.reduce(0) { $0 + $1.plays },
            tracks: trackRows,
            artists: artistRows.values.sorted(by: Self.ranked),
            albums: albumRows.values.sorted(by: Self.ranked),
            genres: [],
            busiestHour: busiestHour?.element == 0 ? nil : busiestHour?.offset,
            busiestHourMilliseconds: busiestHour?.element ?? 0,
            busiestDay: busiestDay?.key,
            busiestDayMilliseconds: busiestDay?.value ?? 0,
            memberSince: memberSince
        )
    }

    private func scheduleFlush() {
        delayedFlush?.cancel()
        delayedFlush = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func availableKeys() -> Set<String> {
        var keys = Set(loaded.keys)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for file in files where file.pathExtension == "json" {
                let key = file.deletingPathExtension().lastPathComponent
                if Self.isMonthKey(key) { keys.insert(key) }
            }
        }
        return keys
    }

    private func bucket(for key: String) -> StoredListeningBucket {
        if let bucket = loaded[key] { return bucket }
        let file = directory.appendingPathComponent("\(key).json")
        if let data = try? Data(contentsOf: file),
           let decoded = try? decoder.decode(StoredListeningBucket.self, from: data) {
            loaded[key] = decoded
            return decoded
        }
        let empty = StoredListeningBucket(month: key)
        loaded[key] = empty
        return empty
    }

    private func mergedMetadata(old: Track, new: Track) -> Track {
        var result = new
        if result.album == nil { result.album = old.album }
        if result.artworkURL == nil { result.artworkURL = old.artworkURL }
        if result.duration == nil { result.duration = old.duration }
        if result.localPath == nil, new.videoID == nil { result.localPath = old.localPath }
        if result.sourceURL == nil { result.sourceURL = old.sourceURL }
        if result.setVideoID == nil { result.setVideoID = old.setVideoID }
        return result
    }

    private static func ranked(_ lhs: ReplayTrackStat, _ rhs: ReplayTrackStat) -> Bool {
        if lhs.milliseconds != rhs.milliseconds { return lhs.milliseconds > rhs.milliseconds }
        if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
        return lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title) == .orderedAscending
    }

    private static func ranked(_ lhs: ReplayNamedStat, _ rhs: ReplayNamedStat) -> Bool {
        if lhs.milliseconds != rhs.milliseconds { return lhs.milliseconds > rhs.milliseconds }
        if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func primaryArtist(_ raw: String) -> String {
        let artist = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return "" }
        let separators = [" feat.", " featuring ", " ft.", " & ", " x ", " vs. ", ","]
        let ranges = separators.compactMap {
            artist.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }
        guard let first = ranges.min(by: { $0.lowerBound < $1.lowerBound }) else { return artist }
        return String(artist[..<first.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func monthKey(for date: Date, calendar: Calendar) -> String {
        let values = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", values.year ?? 0, values.month ?? 0)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            values.year ?? 0,
            values.month ?? 0,
            values.day ?? 0
        )
    }

    private static func isMonthKey(_ key: String) -> Bool {
        guard key.count == 7 else { return false }
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let year = Int(parts[0]), year >= 2000,
              let month = Int(parts[1]), (1...12).contains(month) else { return false }
        return true
    }
}

enum ListeningStatsBackupError: LocalizedError {
    case invalidMonth(String)
    case invalidBucket(String)

    var errorDescription: String? {
        switch self {
        case .invalidMonth(let month): "The backup contains an invalid or duplicate month: \(month)."
        case .invalidBucket(let month): "The listening data for \(month) is invalid."
        }
    }
}

/// Converts audible wall-clock samples into aggregate listening time. Position
/// is intentionally ignored: seeking backwards cannot inflate Replay and a
/// paused player cannot accrue minutes.
@MainActor
final class ListeningRecorder {
    typealias RecordHandler = (Track, TimeInterval, Bool, Date) -> Void

    private let now: () -> Date
    private let onRecord: RecordHandler
    private let onFlush: () -> Void
    private var currentTrack: Track?
    private var lastSampleAt: Date?
    private var playedThisTrack: TimeInterval = 0
    private var pendingSeconds: TimeInterval = 0
    private var pendingPlay = false
    private var playCounted = false

    init(
        now: @escaping () -> Date = Date.init,
        onRecord: @escaping RecordHandler,
        onFlush: @escaping () -> Void = {}
    ) {
        self.now = now
        self.onRecord = onRecord
        self.onFlush = onFlush
    }

    func onSample(track: Track, duration: TimeInterval) {
        let sampledAt = now()
        guard currentTrack?.id == track.id else {
            flushPending(at: sampledAt)
            currentTrack = track
            lastSampleAt = sampledAt
            playedThisTrack = 0
            pendingSeconds = 0
            pendingPlay = false
            playCounted = false
            return
        }

        guard let lastSampleAt else {
            self.lastSampleAt = sampledAt
            return
        }
        let step = min(max(sampledAt.timeIntervalSince(lastSampleAt), 0), 8)
        self.lastSampleAt = sampledAt
        guard step > 0 else { return }
        currentTrack = track
        playedThisTrack += step
        pendingSeconds += step

        let threshold: TimeInterval
        if duration > 0 {
            threshold = min(max(duration / 2, 30), 4 * 60)
        } else {
            threshold = 30
        }
        if !playCounted, playedThisTrack >= threshold {
            playCounted = true
            pendingPlay = true
        }

        if pendingSeconds >= 5 || pendingPlay {
            emitPending(at: sampledAt)
        }
    }

    func onStopped() {
        flushPending(at: now())
        currentTrack = nil
        lastSampleAt = nil
        playedThisTrack = 0
        pendingSeconds = 0
        pendingPlay = false
        playCounted = false
        onFlush()
    }

    private func flushPending(at date: Date) {
        emitPending(at: date)
    }

    private func emitPending(at date: Date) {
        guard let currentTrack, pendingSeconds > 0 || pendingPlay else { return }
        onRecord(currentTrack, pendingSeconds, pendingPlay, date)
        pendingSeconds = 0
        pendingPlay = false
    }
}

/// Preserves record/flush ordering while the store performs disk work off the
/// UI path. In particular, a pause immediately after a five-second sample
/// cannot flush before that sample has reached the actor.
@MainActor
final class ListeningStatsCoordinator {
    private let store: ListeningStatsStore
    private let artistFacts: ArtistFactsStore
    private weak var replay: ReplayViewModel?
    private var tail: Task<Void, Never>?

    init(store: ListeningStatsStore, artistFacts: ArtistFactsStore, replay: ReplayViewModel) {
        self.store = store
        self.artistFacts = artistFacts
        self.replay = replay
    }

    func record(_ track: Track, seconds: TimeInterval, countsAsPlay: Bool, at date: Date) {
        let previous = tail
        tail = Task { [weak self] in
            _ = await previous?.result
            guard let self else { return }
            await store.record(
                track: track,
                playedSeconds: seconds,
                countsAsPlay: countsAsPlay,
                at: date
            )
            await artistFacts.notice(track.artist)
            replay?.markRecorded()
        }
    }

    func flush() {
        let previous = tail
        tail = Task { [weak self] in
            _ = await previous?.result
            guard let self else { return }
            await store.flush()
        }
    }
}

@MainActor
final class ReplayViewModel: ObservableObject {
    @Published var period: ReplayPeriod = .thisYear
    @Published var genresEnabled: Bool {
        didSet {
            defaults.set(genresEnabled, forKey: ArtistFactsStore.settingKey)
            let enabled = genresEnabled
            Task { [weak self, artistFacts] in
                await artistFacts.setEnabled(enabled)
                if enabled, let artists = self?.baseSummary.artists.map(\.title) {
                    await artistFacts.warm(artists: artists)
                }
                await self?.refreshGenreProjection()
            }
        }
    }
    @Published private(set) var summary: ReplaySummary = .empty(.thisYear)
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var revision = 0
    @Published private(set) var genreStatus: ArtistFactsStatus

    private let store: ListeningStatsStore
    private let artistFacts: ArtistFactsStore
    private let defaults: UserDefaults
    private var baseSummary: ReplaySummary = .empty(.thisYear)
    private var factsObservation: Task<Void, Never>?

    init(
        store: ListeningStatsStore,
        artistFacts: ArtistFactsStore? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.defaults = defaults
        let enabled = defaults.object(forKey: ArtistFactsStore.settingKey) as? Bool ?? true
        genresEnabled = enabled
        let facts = artistFacts ?? ArtistFactsStore(enabled: enabled)
        self.artistFacts = facts
        genreStatus = ArtistFactsStatus(
            enabled: enabled,
            cachedArtists: 0,
            queuedArtists: 0,
            lastSource: nil,
            lastError: nil
        )
        factsObservation = Task { [weak self, facts] in
            let revisions = await facts.revisions()
            for await _ in revisions {
                guard !Task.isCancelled else { return }
                await self?.refreshGenreProjection()
            }
        }
    }

    deinit {
        factsObservation?.cancel()
    }

    func markRecorded() {
        revision &+= 1
    }

    func refresh() async {
        let requestedPeriod = period
        isLoading = true
        errorMessage = nil
        let result = await store.summary(for: requestedPeriod)
        guard period == requestedPeriod else { return }
        baseSummary = result
        summary = await artistFacts.applyingGenres(to: result)
        genreStatus = await artistFacts.status()
        isLoading = false
        await artistFacts.warm(artists: result.artists.map(\.title))
    }

    private func refreshGenreProjection() async {
        summary = await artistFacts.applyingGenres(to: baseSummary)
        genreStatus = await artistFacts.status()
    }
}
