import SwiftUI

struct ReplayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var replay: ReplayViewModel
    let compact: Bool
    @State private var storyStart: ReplayStoryPage?

    private var refreshToken: String {
        "\(replay.period.rawValue)-\(replay.revision)"
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    if replay.isLoading, replay.summary.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Building your Replay…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else if replay.summary.isEmpty {
                        emptyState
                    } else {
                        hero
                        metricGrid
                        charts
                        habits
                    }

                    if let errorMessage = replay.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(width: compact ? max(1, proxy.size.width - 48) : nil, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 52)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await replay.refresh()
            }
        }
        .task(id: refreshToken) {
            await replay.refresh()
        }
        .sheet(item: $storyStart) { page in
            ReplayStoriesView(summary: replay.summary, start: page)
        }
    }

    private var header: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 5) {
                    headerTitle
                    periodPicker
                        .padding(.top, 8)
                    replayButton
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    headerTitle
                        .frame(minWidth: 240, alignment: .leading)
                    Spacer()
                    replayButton
                    periodPicker
                }
            }
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Replay")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text("The music you actually played on this Mac")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var replayButton: some View {
        if !replay.summary.isEmpty {
            Button {
                storyStart = .intro
            } label: {
                Label("Play Replay", systemImage: "play.fill")
            }
            .buttonStyle(ReplayPlayButtonStyle())
        }
    }

    private var periodPicker: some View {
        Picker("Period", selection: $replay.period) {
            ForEach(ReplayPeriod.allCases) { period in
                Text(period.title).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.purple.opacity(0.85), .pink.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "sparkles")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 92, height: 92)

            VStack(spacing: 7) {
                Text("Your Replay starts here")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text("Lilt counts only time when audio is really playing.\nListen for a bit and your songs, artists and habits will appear here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            Button("Go to Home") { model.section = .home }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
        }
        .frame(maxWidth: .infinity, minHeight: 390)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var artistChart: some View {
        if !replay.summary.artists.isEmpty {
            namedChart(title: "Top Artists", rows: replay.summary.artists)
        }
    }

    @ViewBuilder
    private var albumChart: some View {
        if !replay.summary.albums.isEmpty {
            namedChart(title: "Top Albums", rows: replay.summary.albums)
        }
    }

    private func namedChart(title: String, rows: [ReplayNamedStat]) -> some View {
        ReplayChartCard(title: title, subtitle: nil) {
            VStack(spacing: 0) {
                ForEach(Array(rows.prefix(5).enumerated()), id: \.element.id) { index, row in
                    ReplayChartRow(
                        rank: index + 1,
                        title: row.title,
                        subtitle: row.subtitle,
                        artworkURL: row.artworkURL,
                        milliseconds: row.milliseconds,
                        plays: row.plays,
                        showsPlay: false
                    )
                    if index < min(rows.count, 5) - 1 { Divider().opacity(0.45) }
                }
            }
        }
    }

    private var hero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.purple.opacity(0.82), .pink.opacity(0.64), .orange.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let urlString = replay.summary.tracks.first?.track.artworkURL,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .opacity(0.38)
                    }
                }
                .mask {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45), .black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
            }

            LinearGradient(
                colors: [.black.opacity(0.05), .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))

        }
        .frame(height: 245)
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 10) {
                Label(replay.summary.period.title.uppercased(), systemImage: "waveform")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.72))

                Text(replayHeadline)
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if let track = replay.summary.tracks.first?.track {
                    Text("Top track · \(track.title) — \(track.artist)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }

                Button {
                    storyStart = .minutes
                } label: {
                    Label("Watch your Replay", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
            }
            .padding(26)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var replayHeadline: String {
        let minutes = replay.summary.totalMinutes
        if minutes == 1 { return "1 minute of your music" }
        if minutes < 60 { return "\(minutes) minutes of your music" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? "\(hours) hours of your music"
            : "\(hours) hr \(remainder) min of your music"
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: 14)],
            alignment: .leading,
            spacing: 14
        ) {
            ReplayMetricCard(
                title: "Minutes listened",
                value: grouped(replay.summary.totalMinutes),
                systemImage: "clock.fill",
                tint: .purple
            )
            ReplayMetricCard(
                title: "Counted plays",
                value: grouped(replay.summary.totalPlays),
                systemImage: "play.fill",
                tint: .pink
            )
            ReplayMetricCard(
                title: "Different songs",
                value: grouped(replay.summary.distinctSongs),
                systemImage: "music.note.list",
                tint: .orange
            )
            ReplayMetricCard(
                title: "Different artists",
                value: grouped(replay.summary.distinctArtists),
                systemImage: "person.2.fill",
                tint: .cyan
            )
            if !replay.summary.genres.isEmpty {
                ReplayMetricCard(
                    title: "Genres",
                    value: grouped(replay.summary.genres.count),
                    systemImage: "tag.fill",
                    tint: .green
                )
            }
        }
    }

    @ViewBuilder
    private var charts: some View {
        if !replay.summary.tracks.isEmpty {
            ReplayChartCard(title: "Top Songs", subtitle: "Ranked by real listening time") {
                VStack(spacing: 0) {
                    ForEach(Array(replay.summary.tracks.prefix(8).enumerated()), id: \.element.id) { index, row in
                        Button {
                            model.play(row.track, queue: replay.summary.tracks.map(\.track))
                        } label: {
                            ReplayChartRow(
                                rank: index + 1,
                                title: row.track.title,
                                subtitle: row.track.artist,
                                artworkURL: row.track.artworkURL,
                                milliseconds: row.milliseconds,
                                plays: row.plays,
                                showsPlay: true
                            )
                        }
                        .buttonStyle(.plain)
                        if index < min(replay.summary.tracks.count, 8) - 1 { Divider().opacity(0.45) }
                    }
                }
            }
        }

        Group {
            if compact {
                VStack(spacing: 16) {
                    artistChart
                    albumChart
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    artistChart
                    albumChart
                }
            }
        }

        if !replay.summary.genres.isEmpty {
            ReplayChartCard(title: "Top Genres", subtitle: "Worked out from your leading artists") {
                VStack(spacing: 0) {
                    ForEach(Array(replay.summary.genres.prefix(8).enumerated()), id: \.element.id) { index, row in
                        ReplayGenreChartRow(rank: index + 1, row: row)
                        if index < min(replay.summary.genres.count, 8) - 1 { Divider().opacity(0.45) }
                    }
                }
            }
        } else if replay.genresEnabled, replay.genreStatus.queuedArtists > 0 {
            ReplayChartCard(title: "Top Genres", subtitle: "Artist names only · listening history stays on this Mac") {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(replay.genreStatus.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var habits: some View {
        ReplayChartCard(title: "Your Rhythm", subtitle: "When Lilt was part of your day") {
            Group {
                if compact {
                    VStack(spacing: 14) {
                        favoriteHourHabit
                        Divider()
                        biggestDayHabit
                        if replay.summary.memberSince != nil {
                            Divider()
                            memberSinceHabit
                        }
                    }
                } else {
                    HStack(spacing: 18) {
                        favoriteHourHabit
                        Divider().frame(height: 76)
                        biggestDayHabit
                        if replay.summary.memberSince != nil {
                            Divider().frame(height: 76)
                            memberSinceHabit
                        }
                    }
                }
            }
        }
    }

    private var favoriteHourHabit: some View {
        ReplayHabit(
            systemImage: "sun.max.fill",
            title: "Favorite hour",
            value: replay.summary.busiestHour.map(formatHour) ?? "—",
            detail: listeningTime(replay.summary.busiestHourMilliseconds),
            tint: .orange
        )
    }

    private var biggestDayHabit: some View {
        ReplayHabit(
            systemImage: "calendar",
            title: "Biggest day",
            value: replay.summary.busiestDay.map(formatDay) ?? "—",
            detail: listeningTime(replay.summary.busiestDayMilliseconds),
            tint: .pink
        )
    }

    private var memberSinceHabit: some View {
        ReplayHabit(
            systemImage: "sparkles",
            title: "Counting since",
            value: replay.summary.memberSince?.formatted(date: .abbreviated, time: .omitted) ?? "—",
            detail: "Stored only on this Mac",
            tint: .purple
        )
    }

    private func grouped(_ number: Int) -> String {
        number.formatted(.number.grouping(.automatic))
    }

    private func listeningTime(_ milliseconds: Int64) -> String {
        let minutes = milliseconds / 60_000
        if minutes < 60 { return "\(minutes) min listened" }
        return "\(minutes / 60) hr \(minutes % 60) min listened"
    }

    private func formatHour(_ hour: Int) -> String {
        switch hour {
        case 0: "Midnight"
        case 12: "Noon"
        case 1...11: "\(hour) AM"
        default: "\(hour - 12) PM"
        }
    }

    private func formatDay(_ value: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return value }
        return date.formatted(.dateTime.day().month(.wide))
    }
}

private struct ReplayMetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct ReplayPlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Color.purple.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct ReplayChartCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct ReplayChartRow: View {
    let rank: Int
    let title: String
    let subtitle: String?
    let artworkURL: String?
    let milliseconds: Int64
    let plays: Int
    let showsPlay: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(rank <= 3 ? Color.pink : Color.secondary)
                .frame(width: 18, alignment: .trailing)
            ArtworkView(url: artworkURL, title: title, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(compactTime(milliseconds))
                    .font(.caption.monospacedDigit().weight(.medium))
                Text(plays == 1 ? "1 play" : "\(plays) plays")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if showsPlay {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.pink)
                    .frame(width: 18)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func compactTime(_ value: Int64) -> String {
        let minutes = value / 60_000
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct ReplayHabit: View {
    let systemImage: String
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 16, weight: .bold, design: .rounded))
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReplayGenreChartRow: View {
    let rank: Int
    let row: ReplayNamedStat

    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(rank <= 3 ? Color.green : Color.secondary)
                .frame(width: 18, alignment: .trailing)
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [genreColor.opacity(0.9), genreColor.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 48, height: 48)
                .overlay {
                    Text(String(row.title.prefix(1)).uppercased())
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
            Text(row.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(compactTime(row.milliseconds))
                    .font(.caption.monospacedDigit().weight(.medium))
                Text(row.plays == 1 ? "1 play" : "\(row.plays) plays")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
    }

    private var genreColor: Color {
        let hash = row.title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.65, brightness: 0.8)
    }

    private func compactTime(_ value: Int64) -> String {
        let minutes = value / 60_000
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
