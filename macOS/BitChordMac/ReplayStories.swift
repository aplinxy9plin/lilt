import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ReplayStoryPage: String, CaseIterable, Identifiable, Sendable {
    case intro
    case minutes
    case artists
    case songs
    case albums
    case genres
    case habits
    case summary

    var id: String { rawValue }

    var hue: Double {
        switch self {
        case .intro: 0.76
        case .minutes: 0.94
        case .artists: 0.56
        case .songs: 0.09
        case .albums: 0.43
        case .genres: 0.34
        case .habits: 0.67
        case .summary: 0.88
        }
    }
}

struct ReplayHeadlineRun: Equatable, Sendable {
    let text: String
    let emphasized: Bool
}

extension ReplaySummary {
    var replayLabel: String {
        switch period {
        case .thisMonth:
            Date.now.formatted(.dateTime.month(.wide).year())
        case .thisYear:
            String(Calendar.current.component(.year, from: .now))
        case .allTime:
            "All time"
        }
    }

    var storyPages: [ReplayStoryPage] {
        ReplayStoryPage.allCases.filter { page in
            switch page {
            case .artists: !artists.isEmpty
            case .songs: !tracks.isEmpty
            case .albums: !albums.isEmpty
            case .genres: !genres.isEmpty
            default: true
            }
        }
    }

    func storyHeadline(for page: ReplayStoryPage) -> [ReplayHeadlineRun] {
        func plain(_ text: String) -> ReplayHeadlineRun {
            ReplayHeadlineRun(text: text, emphasized: false)
        }
        func strong(_ text: String) -> ReplayHeadlineRun {
            ReplayHeadlineRun(text: text, emphasized: true)
        }

        switch page {
        case .intro:
            return [plain("This is your "), strong("Replay"), plain(" —\nthe music you actually played.")]
        case .minutes:
            return [plain("You listened to "), strong("\(groupedReplay(totalMinutes)) minutes"), plain("\nof music.")]
        case .artists:
            return [plain("There was one "), strong("artist"), plain("\nyou never got tired of.")]
        case .songs:
            return [plain("You counted "), strong(replayCount(totalPlays, singular: "play")), plain(".\nOne song became your anthem.")]
        case .albums:
            return [plain("One "), strong("album"), plain(" kept\npulling you back.")]
        case .genres:
            return [plain("There was one "), strong("genre"), plain("\nyou came back to again and again.")]
        case .habits:
            return [plain("You moved through "), strong(replayCount(distinctSongs, singular: "song")), plain("\nby "), strong(replayCount(distinctArtists, singular: "artist")), plain(".")]
        case .summary:
            return [plain("That was "), strong(replayLabel), plain(".")]
        }
    }

    func storyArtworkURL(for page: ReplayStoryPage) -> String? {
        let pool = (tracks.map(\.track.artworkURL) + artists.map(\.artworkURL) + albums.map(\.artworkURL))
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        switch page {
        case .songs:
            return tracks.first?.track.artworkURL ?? pool.first
        case .artists:
            return artists.first?.artworkURL ?? pool.first
        case .albums:
            return albums.first?.artworkURL ?? pool.first
        default:
            guard !pool.isEmpty else { return nil }
            let offset = ReplayStoryPage.allCases.firstIndex(of: page) ?? 0
            return pool[offset % pool.count]
        }
    }
}

struct ReplayShareRequest: Identifiable {
    let id = UUID()
    let summary: ReplaySummary
    let page: ReplayStoryPage?
}

struct ReplayStoriesView: View {
    let summary: ReplaySummary
    let start: ReplayStoryPage

    @Environment(\.dismiss) private var dismiss
    @State private var pageIndex = 0
    @State private var progress = 0.0
    @State private var shareRequest: ReplayShareRequest?

    private var pages: [ReplayStoryPage] { summary.storyPages }
    private var currentPage: ReplayStoryPage {
        pages.indices.contains(pageIndex) ? pages[pageIndex] : .intro
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                let cardHeight = min(geometry.size.height - 54, 820)
                let cardWidth = min(cardHeight * 9 / 16, geometry.size.width - 150)

                HStack(spacing: 22) {
                    navigationButton(systemImage: "chevron.left", enabled: pageIndex > 0) {
                        move(to: pageIndex - 1)
                    }

                    ReplayStoryCard(summary: summary, page: currentPage)
                        .frame(width: cardWidth, height: cardWidth * 16 / 9)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay(alignment: .top) { storyChrome }
                        .shadow(color: .black.opacity(0.5), radius: 35, y: 18)

                    navigationButton(systemImage: "chevron.right", enabled: pageIndex < pages.count - 1) {
                        move(to: pageIndex + 1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 680, minHeight: 660)
        .onAppear {
            pageIndex = pages.firstIndex(of: start) ?? 0
        }
        .onMoveCommand { direction in
            switch direction {
            case .left: move(to: pageIndex - 1)
            case .right: move(to: pageIndex + 1)
            default: break
            }
        }
        .onExitCommand { dismiss() }
        .task(id: "\(pageIndex)-\(shareRequest != nil)") {
            await runAutoAdvance()
        }
        .sheet(item: $shareRequest) { request in
            ReplayShareSheet(request: request)
        }
    }

    private var storyChrome: some View {
        VStack(spacing: 13) {
            HStack(spacing: 5) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, _ in
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.white.opacity(0.24))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(.white)
                                    .frame(width: proxy.size.width * segmentProgress(at: index))
                            }
                    }
                    .frame(height: 3)
                }
            }

            HStack(spacing: 10) {
                Text(replayWordmark)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    shareRequest = ReplayShareRequest(summary: summary, page: currentPage)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(ReplayStoryChromeButtonStyle())
                .help("Share this Replay card")

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(ReplayStoryChromeButtonStyle())
                .help("Close Replay")
            }
        }
        .padding(16)
    }

    private var replayWordmark: String {
        let label = summary.replayLabel
        if label.count == 4, label.allSatisfy(\.isNumber) {
            return "Replay’\(label.suffix(2))  ·  Lilt"
        }
        return "Replay · \(label)  ·  Lilt"
    }

    private func segmentProgress(at index: Int) -> Double {
        if index < pageIndex { return 1 }
        if index > pageIndex { return 0 }
        return progress
    }

    private func navigationButton(
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.2))
                .frame(width: 44, height: 44)
                .background(.white.opacity(enabled ? 0.09 : 0.035), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(systemImage.contains("left") ? "Previous Replay card" : "Next Replay card")
    }

    private func move(to target: Int) {
        guard pages.indices.contains(target) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            progress = 0
            pageIndex = target
        }
    }

    @MainActor
    private func runAutoAdvance() async {
        progress = 0
        guard shareRequest == nil, pageIndex < pages.count - 1 else { return }
        withAnimation(.linear(duration: 7)) { progress = 1 }
        do {
            try await Task.sleep(nanoseconds: 7_000_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled, shareRequest == nil else { return }
        move(to: pageIndex + 1)
    }
}

private struct ReplayStoryChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.black.opacity(configuration.isPressed ? 0.48 : 0.28), in: Circle())
            .contentShape(Circle())
    }
}

private struct ReplayStoryCard: View {
    let summary: ReplaySummary
    let page: ReplayStoryPage

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ReplayStoryBackdrop(page: page, artworkURL: summary.storyArtworkURL(for: page))

                VStack(alignment: .leading, spacing: 0) {
                    headline
                        .frame(width: geometry.size.width * 0.85, alignment: .leading)
                        .lineLimit(4)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .padding(.top, geometry.size.height * 0.15)

                    Spacer(minLength: 18)
                    pageContent(in: geometry.size)
                    Spacer(minLength: 16)

                    HStack {
                        Image(systemName: "waveform")
                        Text("Lilt Replay")
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                }
                .padding(.horizontal, geometry.size.width * 0.075)
                .padding(.bottom, geometry.size.height * 0.045)
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Replay card: \(page.rawValue)")
    }

    private var headline: Text {
        summary.storyHeadline(for: page).reduce(Text("")) { result, run in
            result + Text(run.text).fontWeight(run.emphasized ? .black : .medium)
        }
        .font(.system(size: 23, weight: .medium, design: .rounded))
    }

    @ViewBuilder
    private func pageContent(in size: CGSize) -> some View {
        switch page {
        case .intro:
            ReplayArtworkCollage(summary: summary)
                .frame(height: size.height * 0.51)
        case .minutes:
            VStack(alignment: .leading, spacing: 7) {
                Text(groupedReplay(summary.totalMinutes))
                    .font(.system(size: min(size.width * 0.24, 94), weight: .black, design: .rounded))
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text("minutes")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 12)
                ReplayMiniStat(value: replayCount(summary.totalPlays, singular: "play"), label: "counted")
                ReplayMiniStat(value: replayCount(summary.distinctSongs, singular: "song"), label: "in rotation")
            }
            .frame(maxWidth: .infinity, maxHeight: size.height * 0.48, alignment: .leading)
        case .songs:
            if let top = summary.tracks.first {
                ReplayLeaderboard(
                    title: top.track.title,
                    subtitle: top.track.artist,
                    artworkURL: top.track.artworkURL,
                    detail: replayListeningTime(top.milliseconds),
                    runners: summary.tracks.dropFirst().prefix(3).map {
                        ($0.track.title, $0.track.artist, $0.track.artworkURL, replayListeningTime($0.milliseconds))
                    },
                    circular: false
                )
            }
        case .artists:
            if let top = summary.artists.first {
                ReplayLeaderboard(
                    title: top.title,
                    subtitle: nil,
                    artworkURL: top.artworkURL,
                    detail: replayListeningTime(top.milliseconds),
                    runners: summary.artists.dropFirst().prefix(3).map {
                        ($0.title, $0.subtitle, $0.artworkURL, replayListeningTime($0.milliseconds))
                    },
                    circular: true
                )
            }
        case .albums:
            if let top = summary.albums.first {
                ReplayLeaderboard(
                    title: top.title,
                    subtitle: top.subtitle,
                    artworkURL: top.artworkURL,
                    detail: replayListeningTime(top.milliseconds),
                    runners: summary.albums.dropFirst().prefix(3).map {
                        ($0.title, $0.subtitle, $0.artworkURL, replayListeningTime($0.milliseconds))
                    },
                    circular: false
                )
            }
        case .genres:
            if let top = summary.genres.first {
                VStack(alignment: .leading, spacing: 14) {
                    Text(top.title)
                        .font(.system(size: 47, weight: .black, design: .rounded))
                        .minimumScaleFactor(0.65)
                        .lineLimit(2)
                    Text(replayListeningTime(top.milliseconds))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    ForEach(Array(summary.genres.dropFirst().prefix(4).enumerated()), id: \.element.id) { index, genre in
                        HStack(spacing: 11) {
                            Text("\(index + 2)")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 18, alignment: .trailing)
                            Text(genre.title)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .lineLimit(1)
                            Spacer()
                            Text(replayListeningTime(genre.milliseconds))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .habits:
            VStack(alignment: .leading, spacing: 18) {
                if let hour = summary.busiestHour {
                    ReplayLargeFact(value: replayHour(hour), label: "when you listened most")
                }
                if let day = summary.busiestDay {
                    ReplayLargeFact(value: replayDay(day), label: "your biggest listening day")
                }
                if let memberSince = summary.memberSince {
                    ReplayLargeFact(
                        value: memberSince.formatted(.dateTime.month(.abbreviated).year()),
                        label: "Lilt has been counting since"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .summary:
            VStack(alignment: .leading, spacing: 17) {
                ReplayRecapLine(label: "Minutes", value: groupedReplay(summary.totalMinutes))
                ReplayRecapLine(label: "Top song", value: summary.tracks.first?.track.title ?? "—")
                ReplayRecapLine(label: "Top artist", value: summary.artists.first?.title ?? "—")
                ReplayRecapLine(label: "Top album", value: summary.albums.first?.title ?? "—")
                if let genre = summary.genres.first {
                    ReplayRecapLine(label: "Top genre", value: genre.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ReplayStoryBackdrop: View {
    let page: ReplayStoryPage
    let artworkURL: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: page.hue, saturation: 0.74, brightness: 0.58),
                    Color(hue: (page.hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.78, brightness: 0.38),
                    Color(hue: (page.hue + 0.91).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            ReplayRemoteArtwork(urlString: artworkURL, title: page.rawValue, circular: false)
                .scaledToFill()
                .blur(radius: 42)
                .opacity(0.22)
                .scaleEffect(1.25)

            LinearGradient(
                colors: [.black.opacity(0.5), .clear, .black.opacity(0.48)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
    }
}

private struct ReplayArtworkCollage: View {
    let summary: ReplaySummary

    private var artwork: [(String?, String, Bool)] {
        let songs = summary.tracks.prefix(3).map { ($0.track.artworkURL, $0.track.title, false) }
        let artists = summary.artists.prefix(3).map { ($0.artworkURL, $0.title, true) }
        return Array((songs + artists).prefix(6))
    }

    var body: some View {
        GeometryReader { proxy in
            let placements: [(CGFloat, CGFloat, CGFloat, Double)] = [
                (0.15, 0.11, 0.46, -8), (0.52, 0.02, 0.34, 9), (0.46, 0.43, 0.44, -3),
                (0.02, 0.51, 0.30, 7), (0.69, 0.66, 0.25, 5), (0.22, 0.74, 0.22, -9)
            ]
            ForEach(Array(artwork.enumerated()), id: \.offset) { index, item in
                let placement = placements[index]
                let side = proxy.size.width * placement.2
                ReplayRemoteArtwork(urlString: item.0, title: item.1, circular: item.2)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: item.2 ? side / 2 : side * 0.1))
                    .rotationEffect(.degrees(placement.3))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                    .position(x: proxy.size.width * placement.0 + side / 2, y: proxy.size.height * placement.1 + side / 2)
            }
        }
    }
}

private struct ReplayLeaderboard: View {
    let title: String
    let subtitle: String?
    let artworkURL: String?
    let detail: String
    let runners: [(String, String?, String?, String)]
    let circular: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 16) {
                ReplayRemoteArtwork(urlString: artworkURL, title: title, circular: circular)
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: circular ? 64 : 18))
                    .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
                VStack(alignment: .leading, spacing: 5) {
                    Text("#1").font(.caption.bold()).foregroundStyle(.white.opacity(0.55))
                    Text(title)
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .lineLimit(3)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.67)).lineLimit(2)
                    }
                    Text(detail).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                }
            }

            ForEach(Array(runners.enumerated()), id: \.offset) { index, runner in
                HStack(spacing: 10) {
                    Text("\(index + 2)")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(width: 16, alignment: .trailing)
                    ReplayRemoteArtwork(urlString: runner.2, title: runner.0, circular: circular)
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: circular ? 21 : 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(runner.0).font(.system(size: 12, weight: .bold)).lineLimit(1)
                        if let subtitle = runner.1, !subtitle.isEmpty {
                            Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(runner.3).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.54))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReplayMiniStat: View {
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(.system(size: 20, weight: .black, design: .rounded))
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct ReplayLargeFact: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 31, weight: .black, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.58))
        }
    }
}

private struct ReplayRecapLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.48))
            Text(value).font(.system(size: 22, weight: .black, design: .rounded)).lineLimit(2)
        }
    }
}

private struct ReplayRemoteArtwork: View {
    let urlString: String?
    let title: String
    let circular: Bool

    var body: some View {
        AsyncImage(url: urlString.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    LinearGradient(colors: [.white.opacity(0.24), .black.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(title.prefix(1)).uppercased())
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .clipped()
    }
}

struct ReplayPosterPayload: Equatable, Sendable {
    let label: String
    let minutes: String
    let plays: String
    let songs: String
    let topSong: String?
    let topSongArtist: String?
    let topArtist: String?
    let topAlbum: String?
    let topGenre: String?
    let favoriteHour: String?
    let biggestDay: String?

    init(summary: ReplaySummary) {
        label = summary.replayLabel
        minutes = groupedReplay(summary.totalMinutes)
        plays = replayCount(summary.totalPlays, singular: "play")
        songs = replayCount(summary.distinctSongs, singular: "song")
        topSong = summary.tracks.first?.track.title
        topSongArtist = summary.tracks.first?.track.artist
        topArtist = summary.artists.first?.title
        topAlbum = summary.albums.first?.title
        topGenre = summary.genres.first?.title
        favoriteHour = summary.busiestHour.map(replayHour)
        biggestDay = summary.busiestDay.map(replayDay)
    }
}

enum ReplayPosterError: LocalizedError {
    case imageUnavailable
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .imageUnavailable: "Lilt could not draw the Replay poster."
        case .pngEncodingFailed: "Lilt could not encode the Replay poster as PNG."
        }
    }
}

@MainActor
enum ReplayPosterRenderer {
    static let size = CGSize(width: 1080, height: 1920)

    static func render(summary: ReplaySummary, page: ReplayStoryPage?) async throws -> URL {
        let artworkURL = summary.storyArtworkURL(for: page ?? .summary).flatMap(URL.init(string:))
        let artwork = await loadArtwork(at: artworkURL)
        let view = ReplayPosterCanvas(summary: summary, page: page, artwork: artwork)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
        guard let image = renderer.nsImage else { throw ReplayPosterError.imageUnavailable }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ReplayPosterError.pngEncodingFailed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChord-Replay", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = page?.rawValue ?? "complete"
        let target = directory.appendingPathComponent("bitchord-replay-\(suffix).png")
        try png.write(to: target, options: .atomic)
        return target
    }

    private static func loadArtwork(at url: URL?) async -> NSImage? {
        guard let url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) != false else { return nil }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }
}

private struct ReplayPosterCanvas: View {
    let summary: ReplaySummary
    let page: ReplayStoryPage?
    let artwork: NSImage?

    private var payload: ReplayPosterPayload { ReplayPosterPayload(summary: summary) }
    private var hue: Double { page?.hue ?? ReplayStoryPage.summary.hue }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.76, brightness: 0.6),
                    Color(hue: (hue + 0.14).truncatingRemainder(dividingBy: 1), saturation: 0.78, brightness: 0.35),
                    Color(hue: (hue + 0.9).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1180, height: 2020)
                    .blur(radius: 90)
                    .opacity(0.2)
            }

            LinearGradient(
                colors: [.black.opacity(0.48), .clear, .black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(posterReplayTitle)
                        .font(.system(size: 48, weight: .black, design: .rounded))
                    Spacer()
                    Image(systemName: "waveform")
                    Text("Lilt").font(.system(size: 40, weight: .black, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.95))

                Spacer()

                if let page {
                    posterPage(page)
                } else {
                    completePoster
                }

                Spacer()

                Text("YOUR MUSIC · COUNTED ONLY WHILE IT WAS REALLY PLAYING")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .tracking(2.8)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(88)
        }
        .frame(width: 1080, height: 1920)
        .clipped()
        .foregroundStyle(.white)
    }

    private var posterReplayTitle: String {
        let label = payload.label
        if label.count == 4, label.allSatisfy(\.isNumber) { return "Replay’\(label.suffix(2))" }
        return "Replay · \(label)"
    }

    private var completePoster: some View {
        VStack(alignment: .leading, spacing: 44) {
            Text(payload.minutes)
                .font(.system(size: 205, weight: .black, design: .rounded))
                .minimumScaleFactor(0.55)
                .lineLimit(1)
            Text("minutes of music")
                .font(.system(size: 70, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))

            posterRule
            posterFact("Top song", payload.topSong, detail: payload.topSongArtist)
            posterFact("Top artist", payload.topArtist)
            posterFact("Top album", payload.topAlbum)
            posterFact("Top genre", payload.topGenre)
            posterRule

            HStack(alignment: .top, spacing: 58) {
                posterMetric(value: payload.plays, label: "counted")
                posterMetric(value: payload.songs, label: "in rotation")
            }
            if let hour = payload.favoriteHour {
                posterMetric(value: hour, label: "when you listened most")
            }
        }
    }

    @ViewBuilder
    private func posterPage(_ page: ReplayStoryPage) -> some View {
        VStack(alignment: .leading, spacing: 48) {
            posterHeadline(summary.storyHeadline(for: page))
            posterRule
            switch page {
            case .intro:
                posterMetric(value: payload.minutes, label: "minutes listened")
                posterFact("Top song", payload.topSong, detail: payload.topSongArtist)
                posterFact("Top artist", payload.topArtist)
            case .minutes:
                Text(payload.minutes)
                    .font(.system(size: 230, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text("minutes")
                    .font(.system(size: 80, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            case .songs:
                posterFact("Your anthem", payload.topSong, detail: payload.topSongArtist)
                posterMetric(value: payload.plays, label: "counted")
            case .artists:
                posterFact("Your artist", payload.topArtist)
                posterMetric(value: replayCount(summary.distinctArtists, singular: "artist"), label: "in your Replay")
            case .albums:
                posterFact("Your album", payload.topAlbum)
                posterMetric(value: replayCount(summary.albums.count, singular: "album"), label: "in rotation")
            case .genres:
                posterFact("Your genre", payload.topGenre)
                posterMetric(value: replayCount(summary.genres.count, singular: "genre"), label: "in your Replay")
            case .habits:
                if let hour = payload.favoriteHour { posterMetric(value: hour, label: "when you listened most") }
                if let day = payload.biggestDay { posterMetric(value: day, label: "your biggest listening day") }
                posterMetric(value: payload.songs, label: "different songs")
            case .summary:
                posterFact("Top song", payload.topSong, detail: payload.topSongArtist)
                posterFact("Top artist", payload.topArtist)
                posterFact("Top album", payload.topAlbum)
                posterFact("Top genre", payload.topGenre)
                posterMetric(value: payload.minutes, label: "minutes listened")
            }
        }
    }

    private func posterHeadline(_ runs: [ReplayHeadlineRun]) -> Text {
        runs.reduce(Text("")) { result, run in
            result + Text(run.text).fontWeight(run.emphasized ? .black : .semibold)
        }
        .font(.system(size: 72, weight: .semibold, design: .rounded))
    }

    private var posterRule: some View {
        Rectangle().fill(.white.opacity(0.22)).frame(height: 2)
    }

    private func posterFact(_ label: String, _ value: String?, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label.uppercased())
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .tracking(2.5)
                .foregroundStyle(.white.opacity(0.48))
            Text(value ?? "—")
                .font(.system(size: 60, weight: .black, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.68)
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
            }
        }
    }

    private func posterMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(value)
                .font(.system(size: 55, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label).font(.system(size: 29, weight: .semibold)).foregroundStyle(.white.opacity(0.52))
        }
    }
}

struct ReplayShareSheet: View {
    let request: ReplayShareRequest

    @Environment(\.dismiss) private var dismiss
    @State private var posterURL: URL?
    @State private var preview: NSImage?
    @State private var errorMessage: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Share my Replay")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(request.page == nil ? "One poster with the whole Replay." : "The card you were looking at, as a 1080 × 1920 picture.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.05))
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(8)
                } else if let errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(errorMessage).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .padding(24)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Drawing your Replay…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 270, height: 480)
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Button {
                    savePoster()
                } label: {
                    Label(saved ? "Saved" : "Save PNG", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(posterURL == nil || saved)

                if let posterURL {
                    ShareLink(item: posterURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                } else {
                    Button(action: {}) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .task(id: request.id) { await renderPoster() }
    }

    @MainActor
    private func renderPoster() async {
        posterURL = nil
        preview = nil
        errorMessage = nil
        do {
            let url = try await ReplayPosterRenderer.render(summary: request.summary, page: request.page)
            posterURL = url
            preview = NSImage(contentsOf: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func savePoster() {
        guard let posterURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Lilt-Replay-\(request.summary.replayLabel.replacingOccurrences(of: " ", with: "-"))\(request.page.map { "-\($0.rawValue)" } ?? "").png"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            let data = try Data(contentsOf: posterURL)
            try data.write(to: target, options: .atomic)
            saved = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

func groupedReplay(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
}

func replayCount(_ value: Int, singular: String) -> String {
    "\(groupedReplay(value)) \(singular)\(value == 1 ? "" : "s")"
}

func replayListeningTime(_ milliseconds: Int64) -> String {
    let minutes = milliseconds / 60_000
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60) hr \(minutes % 60) min"
}

func replayHour(_ hour: Int) -> String {
    switch hour {
    case 0: "midnight"
    case 12: "midday"
    case 1...11: "\(hour) am"
    default: "\(hour - 12) pm"
    }
}

func replayDay(_ value: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value) else { return value }
    return date.formatted(.dateTime.day().month(.wide))
}
