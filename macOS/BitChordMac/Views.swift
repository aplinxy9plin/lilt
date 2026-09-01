import AppKit
import SwiftUI
import WebKit

struct BitChordRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlaybackController
    @ObservedObject private var downloads: DownloadManager
    @ObservedObject private var playbackSettings: PlaybackSettings
    @State private var showNowPlaying = false
    @StateObject private var artworkTheme = ArtworkThemeLoader()

    init(model: AppModel, player: PlaybackController) {
        self.model = model
        self.player = player
        _downloads = ObservedObject(wrappedValue: model.downloads)
        _playbackSettings = ObservedObject(wrappedValue: model.playbackSettings)
    }

    private var artworkThemeRequestKey: String {
        "\(playbackSettings.dynamicArtworkTheme)|\(player.currentTrack?.artworkURL ?? "none")"
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $model.section,
                libraryCount: model.libraryItemCount,
                downloads: model.downloads,
                youtubeSignedIn: model.youtubeSignedIn,
                onSignIn: { model.showLogin = true },
                onSignOut: model.signOutYouTube,
                onImport: model.importAudio
            )
            .ignoresSafeArea(.container, edges: .top)
        } detail: {
            ZStack {
                BitChordBackground()
                detailView
            }
            .ignoresSafeArea(.container, edges: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.currentTrack != nil {
                    MiniPlayer(
                        player: player,
                        theme: artworkTheme.colors,
                        reduceDynamicBlur: playbackSettings.reduceDynamicBlur,
                        onExpand: { showNowPlaying = true }
                    )
                    .environment(\.colorScheme, .dark)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_020, minHeight: 680)
        .preferredColorScheme(playbackSettings.themeMode.preferredColorScheme)
        .overlay(alignment: .topTrailing) {
            if model.linkLoading {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Opening YouTube Music link…")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background {
                    if playbackSettings.reduceDynamicBlur {
                        Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
                .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                .padding(18)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.linkLoading)
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(
                model: model,
                player: player,
                artworkTheme: artworkTheme,
                canvas: model.canvas
            )
        }
        .task(id: artworkThemeRequestKey) {
            await artworkTheme.load(
                urlString: player.currentTrack?.artworkURL,
                enabled: playbackSettings.dynamicArtworkTheme
            )
        }
        .sheet(isPresented: $model.showLogin) {
            YouTubeLoginView { cookie in
                model.completeYouTubeLogin(cookie: cookie)
            }
        }
        .sheet(item: $model.selectedBrowseItem) { item in
            CollectionDetailView(model: model, item: item)
        }
        .sheet(item: $model.playlistTrack) { track in
            PlaylistPickerView(model: model, track: track)
        }
        .sheet(isPresented: $model.showHistory) {
            HistoryView(model: model)
        }
        .sheet(isPresented: $model.showCreatePlaylist) {
            NewPlaylistView(model: model)
        }
        .sheet(isPresented: $model.showOpenLink) {
            OpenMusicLinkView(model: model)
        }
        .sheet(item: $model.pendingBackupCandidate) { candidate in
            BackupRestoreSheet(model: model, candidate: candidate)
        }
        .alert("Playback", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { if !$0 { player.errorMessage = nil } }
        )) {
            if model.youtubeSignedIn {
                Button("Retry") {
                    player.errorMessage = nil
                    player.retryCurrent()
                }
            } else {
                Button("Sign in to YouTube") {
                    player.errorMessage = nil
                    model.showLogin = true
                }
            }
            Button("Close", role: .cancel) { player.errorMessage = nil }
        } message: {
            Text(player.errorMessage ?? "")
        }
        .alert("YouTube Music", isPresented: Binding(
            get: { model.accountActionError != nil },
            set: { if !$0 { model.accountActionError = nil } }
        )) {
            Button("Close", role: .cancel) { model.accountActionError = nil }
        } message: {
            Text(model.accountActionError ?? "")
        }
        .alert("Open YouTube Music Link", isPresented: Binding(
            get: { model.linkError != nil },
            set: { if !$0 { model.linkError = nil } }
        )) {
            Button("Close", role: .cancel) { model.linkError = nil }
        } message: {
            Text(model.linkError ?? "")
        }
        .alert("Downloads", isPresented: Binding(
            get: { downloads.networkRestrictionMessage != nil },
            set: { if !$0 { downloads.networkRestrictionMessage = nil } }
        )) {
            Button("Open Settings") {
                downloads.networkRestrictionMessage = nil
                model.section = .settings
            }
            Button("Close", role: .cancel) { downloads.networkRestrictionMessage = nil }
        } message: {
            Text(downloads.networkRestrictionMessage ?? "")
        }
        .onOpenURL(perform: model.openMusicLink)
        .onChange(of: model.nowPlayingRequestID) { requestID in
            if requestID != nil { showNowPlaying = true }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch model.section {
        case .home:
            HomeView(model: model)
        case .explore:
            ExploreView(model: model)
        case .search:
            SearchView(model: model)
        case .library:
            LibraryView(model: model)
        case .downloads:
            DownloadsView(model: model)
        case .replay:
            ReplayView(model: model, replay: model.replay)
        case .settings:
            PlaybackSettingsView(
                model: model,
                settings: model.playbackSettings,
                player: player,
                downloads: model.downloads,
                sources: model.sources,
                scrobbling: model.scrobbling,
                lyricsSettings: model.lyricsSettings,
                equalizer: model.equalizer
            )
        }
    }
}

private struct OpenMusicLinkView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var value = ""

    private var isValid: Bool { MusicLinkParser.parse(value) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 31))
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open in Lilt")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Play a shared song or open its collection without leaving the app.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                TextField("https://music.youtube.com/watch?v=…", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(open)
                Button("Paste") {
                    value = NSPasteboard.general.string(forType: .string) ?? ""
                }
            }

            Text("Songs, albums, artists, playlists, searches and youtu.be links are supported. Text copied from a share sheet works too.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(26)
        .frame(width: 560)
        .background(BitChordBackground())
        .onAppear {
            if let clipboard = NSPasteboard.general.string(forType: .string),
               MusicLinkParser.parse(clipboard) != nil {
                value = clipboard
            }
            focused = true
        }
    }

    private func open() {
        guard isValid else { return }
        model.openMusicLink(value)
    }
}

struct SidebarView: View {
    @Binding var selection: AppSection
    let libraryCount: Int
    @ObservedObject var downloads: DownloadManager
    let youtubeSignedIn: Bool
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onImport: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lilt")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("personal player")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 48)
            .padding(.bottom, 26)

            Text("LISTEN")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            VStack(spacing: 3) {
                ForEach(AppSection.allCases) { item in
                    SidebarRow(item: item, selected: selection == item, count: count(for: item)) {
                        withAnimation(.easeOut(duration: 0.18)) { selection = item }
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            if youtubeSignedIn {
                Button(action: onSignOut) {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("YouTube Music")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Connected · Sign out")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            } else {
                Button(action: onSignIn) {
                    HStack(spacing: 9) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .foregroundStyle(.purple)
                        Text("Sign in to YouTube")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            Button(action: onImport) {
                HStack(spacing: 9) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.purple)
                    Text("Add music")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "command")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 218, idealWidth: 228, maxWidth: 260)
        .background(.black.opacity(colorScheme == .dark ? 0.18 : 0.035))
    }

    private func count(for item: AppSection) -> Int? {
        switch item {
        case .library: libraryCount
        case .downloads: downloads.saved.count
        default: nil
        }
    }
}

private struct SidebarRow: View {
    let item: AppSection
    let selected: Bool
    let count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(selected ? .primary : .secondary)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selected ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.55))
                }
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(selected ? Color.primary.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

struct HomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Home")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text(model.youtubeSignedIn ? "From your YouTube Music account" : "YouTube Music recommendations")
                        .foregroundStyle(.secondary)
                }

                if model.homeLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing your mix…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let homeError = model.homeError {
                    InlineNotice(text: homeError, actionTitle: "Retry", action: model.refreshHome)
                }

                ForEach(model.homeShelves) { shelf in
                    ShelfView(
                        shelf: shelf,
                        model: model,
                        player: model.player,
                        downloads: model.downloads,
                        onPlay: { track, queue in model.play(track, queue: queue) },
                        onOpen: model.openBrowseItem
                    )
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 28)
            .padding(.bottom, 42)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await model.refreshHomeFromPull()
        }
    }
}

struct ExploreView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Explore")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("New releases, moods and charts from YouTube Music")
                        .foregroundStyle(.secondary)
                }

                if model.exploreLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Finding what’s moving…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let exploreError = model.exploreError {
                    InlineNotice(text: exploreError, actionTitle: "Retry", action: model.refreshExplore)
                }

                ForEach(model.exploreShelves) { shelf in
                    ShelfView(
                        shelf: shelf,
                        model: model,
                        player: model.player,
                        downloads: model.downloads,
                        // Android starts Explore songs as radio seeds. A
                        // single-item queue lets autoplay build that radio
                        // instead of treating the visible shelf as an album.
                        onPlay: { track, _ in model.play(track, queue: [track]) },
                        onOpen: model.openBrowseItem
                    )
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 28)
            .padding(.bottom, 42)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await model.refreshExploreFromPull()
        }
    }
}

private struct ShelfView: View {
    let shelf: HomeShelf
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlaybackController
    @ObservedObject var downloads: DownloadManager
    let onPlay: (Track, [Track]) -> Void
    let onOpen: (BrowseItem) -> Void

    private var tracks: [Track] { shelf.items.compactMap(\.track) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 3) {
                Text(shelf.title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                if !shelf.subtitle.isEmpty {
                    Text(shelf.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.items) { item in
                        ShelfCard(item: item, model: model, player: player, downloads: downloads) {
                            if let track = item.track {
                                onPlay(track, tracks.isEmpty ? [track] : tracks)
                            } else if let browse = item.browseItem {
                                onOpen(browse)
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct ShelfCard: View {
    let item: ShelfItem
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlaybackController
    @ObservedObject var downloads: DownloadManager
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    ArtworkView(url: item.artworkURL, title: item.title, size: 156)
                    if let browse = item.browseItem, model.isPinned(browse) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.purple, in: Circle())
                            .padding(8)
                            .accessibilityLabel("Pinned playlist")
                    }
                }
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 156, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let track = item.track {
                YouTubeTrackMenuActions(model: model, track: track)
                Divider()
                TrackQueueMenuActions(player: player, track: track)
                Divider()
                TrackNavigationMenuActions(model: model, track: track)
                Divider()
                DownloadMenuAction(downloads: downloads, track: track)
            } else if let browse = item.browseItem {
                Button(action: action) {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                if browse.kind == .playlist {
                    Divider()
                    Button { model.togglePinned(browse) } label: {
                        Label(
                            model.isPinned(browse) ? "Unpin Playlist" : "Pin Playlist",
                            systemImage: model.isPinned(browse) ? "pin.slash" : "pin"
                        )
                    }
                }
            }
        }
    }
}

struct SearchView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    private var tracks: [Track] {
        model.results.compactMap {
            if case .track(let track) = $0 { return track }
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search music", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .focused($searchFocused)
                    .onSubmit(model.submitSearch)
                if !model.query.isEmpty {
                    Button { model.clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: model.submitSearch) {
                    Text("Search")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .padding(.horizontal, 34)
            .padding(.top, 28)

            Picker("Filter", selection: $model.filter) {
                ForEach(SearchFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .onChange(of: model.filter) { _ in
                if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.submitSearch() }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.searchLoading {
                        ProgressView("Searching…")
                            .frame(maxWidth: .infinity, minHeight: 190)
                    } else if let error = model.searchError {
                        InlineNotice(text: error, actionTitle: "Try again", action: model.submitSearch)
                            .padding(.top, 28)
                    } else if model.results.isEmpty {
                        SearchEmptyState(history: model.searchHistory, onSelect: model.useHistory, onFocus: { searchFocused = true })
                            .frame(maxWidth: .infinity)
                            .padding(.top, 36)
                    } else {
                        Text("Results")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .padding(.top, 8)
                        LazyVStack(spacing: 0) {
                            ForEach(model.results) { result in
                                SearchResultRow(
                                    result: result,
                                    model: model,
                                    player: model.player,
                                    downloads: model.downloads,
                                    onPlay: { track in model.play(track, queue: tracks) },
                                    onOpen: open(result)
                                )
                                Divider().opacity(0.35)
                            }
                        }
                    }
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func open(_ result: SearchResult) -> () -> Void {
        {
            switch result {
            case .track(let track):
                if let url = track.youtubeURL { NSWorkspace.shared.open(url) }
            case .browse(let item):
                model.openBrowseItem(item)
            }
        }
    }
}

private struct SearchEmptyState: View {
    let history: [String]
    let onSelect: (String) -> Void
    let onFocus: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(.purple.opacity(0.16)).frame(width: 82, height: 82)
                Image(systemName: "sparkles")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.purple)
            }
            Text("Find something to play")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Search across YouTube Music and enabled audio sources,\nor add your own files from the Library section.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent searches")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(history.prefix(5), id: \.self) { term in
                        Button { onSelect(term) } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 340)
                .padding(.top, 12)
            } else {
                Button("Start searching") { onFocus() }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
            }
        }
    }
}

private struct SearchResultRow: View {
    let result: SearchResult
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlaybackController
    @ObservedObject var downloads: DownloadManager
    let onPlay: (Track) -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: primaryAction) {
            HStack(spacing: 14) {
                switch result {
                case .track(let track):
                    ArtworkView(url: track.artworkURL, title: track.title, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(track.artist).lineLimit(1)
                            if let source = track.catalogSource {
                                Text(source.title.uppercased())
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundStyle(.pink)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.pink.opacity(0.12), in: Capsule())
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !track.durationText.isEmpty {
                        Text(track.durationText).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    playbackAccessory(for: track)
                case .browse(let item):
                    ArtworkView(url: item.artworkURL, title: item.title, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(item.kind.title) · \(item.subtitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if case .track(let track) = result {
                YouTubeTrackMenuActions(model: model, track: track)
                Divider()
                TrackQueueMenuActions(player: player, track: track)
                Divider()
                TrackNavigationMenuActions(model: model, track: track)
                Divider()
                DownloadMenuAction(downloads: downloads, track: track)
            }
            if case .browse = result {
                Button("Open", action: onOpen)
            } else if case .track(let track) = result, track.youtubeURL != nil {
                Button("Open in YouTube Music", action: onOpen)
            }
        }
    }

    private func primaryAction() {
        switch result {
        case .track(let track): onPlay(track)
        case .browse: onOpen()
        }
    }

    @ViewBuilder
    private func playbackAccessory(for track: Track) -> some View {
        if player.isLoading(track) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: player.isCurrent(track) && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                .frame(width: 28, height: 28)
                .foregroundStyle(player.isCurrent(track) ? .white : .purple)
                .background(player.isCurrent(track) ? Color.purple : Color.clear, in: Circle())
        }
    }
}

struct LibraryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Library")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Your music, close at hand")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.youtubeSignedIn {
                    Button { model.showCreatePlaylist = true } label: {
                        Label("New Playlist", systemImage: "text.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    Button(action: model.openHistory) {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                }
                Button(action: model.importAudio) {
                    Label("Add files", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Button(action: model.addLocalFolder) {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 24)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if !model.youtubeSignedIn {
                        InlineNotice(
                            text: "Sign in to see your YouTube Music playlists, albums and artists.",
                            actionTitle: "Sign in",
                            action: { model.showLogin = true }
                        )
                    } else {
                        if model.libraryLoading {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Loading your YouTube Music library…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let error = model.libraryError {
                            InlineNotice(text: error, actionTitle: "Retry", action: model.refreshLibrary)
                        }
                        ForEach(model.libraryShelves) { shelf in
                            ShelfView(
                                shelf: shelf,
                                model: model,
                                player: model.player,
                                downloads: model.downloads,
                                onPlay: { track, queue in model.play(track, queue: queue) },
                                onOpen: model.openBrowseItem
                            )
                        }
                    }

                    LocalLibrarySection(model: model)
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await model.refreshLibraryFromPull()
            }
        }
        .onAppear {
            if model.youtubeSignedIn && model.libraryShelves.isEmpty && !model.libraryLoading {
                model.refreshLibrary()
            }
        }
    }
}

private enum LocalLibraryTab: String, CaseIterable, Identifiable {
    case songs
    case artists
    case albums
    case folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .songs: "Songs"
        case .artists: "Artists"
        case .albums: "Albums"
        case .folders: "Folders"
        }
    }

    var systemImage: String {
        switch self {
        case .songs: "music.note"
        case .artists: "person.2.fill"
        case .albums: "square.stack.fill"
        case .folders: "folder.fill"
        }
    }

    var collectionKind: LocalMediaCollection.Kind? {
        switch self {
        case .songs: nil
        case .artists: .artist
        case .albums: .album
        case .folders: .folder
        }
    }
}

private struct LocalLibrarySection: View {
    @ObservedObject var model: AppModel
    @State private var tab: LocalLibraryTab = .songs
    @State private var query = ""
    @State private var selectedCollection: LocalMediaCollection?

    private var filteredTracks: [Track] {
        LocalLibraryOrganizer.filtered(model.localTracks, query: query)
    }

    private var filteredCollections: [LocalMediaCollection] {
        guard let kind = tab.collectionKind else { return [] }
        let collections = model.localCollections(kind)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return collections }
        return collections.filter { collection in
            collection.title.localizedCaseInsensitiveContains(needle) ||
                collection.subtitle.localizedCaseInsensitiveContains(needle) ||
                collection.tracks.contains {
                    $0.title.localizedCaseInsensitiveContains(needle) ||
                        $0.artist.localizedCaseInsensitiveContains(needle) ||
                        ($0.album?.localizedCaseInsensitiveContains(needle) == true)
                }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("On This Mac")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("\(model.localTracks.count) songs · metadata and artwork from your files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.localLibraryLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: model.refreshLocalLibrary) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.localLibraryLoading)
                Button(action: model.addLocalFolder) {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search local music", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Picker("Local library view", selection: $tab) {
                    ForEach(LocalLibraryTab.allCases) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 430)
            }

            if let error = model.localLibraryError {
                InlineNotice(text: error, actionTitle: "Rescan", action: model.refreshLocalLibrary)
            }

            if tab == .songs {
                localSongList
            } else {
                collectionGrid
            }
        }
        .padding(18)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .sheet(item: $selectedCollection) { collection in
            LocalCollectionDetailView(model: model, collection: collection)
        }
    }

    @ViewBuilder
    private var localSongList: some View {
        if filteredTracks.isEmpty {
            localEmptyState
        } else {
            LazyVStack(spacing: 0) {
                ForEach(filteredTracks) { track in
                    TrackListRow(
                        track: track,
                        model: model,
                        player: model.player,
                        downloads: model.downloads,
                        onPlay: { model.play(track, queue: filteredTracks) }
                    )
                    Divider().opacity(0.35)
                }
            }
        }
    }

    @ViewBuilder
    private var collectionGrid: some View {
        if filteredCollections.isEmpty {
            localEmptyState
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)], spacing: 20) {
                ForEach(filteredCollections) { collection in
                    LocalCollectionCard(collection: collection) {
                        selectedCollection = collection
                    }
                    .contextMenu {
                        if let folderID = collection.folderID {
                            Button { model.revealLocalFolder(folderID) } label: {
                                Label("Show in Finder", systemImage: "finder")
                            }
                            Divider()
                            Button(role: .destructive) { model.removeLocalFolder(folderID) } label: {
                                Label("Remove Folder from Lilt", systemImage: "minus.circle")
                            }
                        }
                    }
                }
            }
        }
    }

    private var localEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: tab == .folders ? "folder.badge.plus" : "music.note.list")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.purple)
            Text(query.isEmpty ? "Add music from this Mac" : "Nothing matches your search")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            if query.isEmpty {
                Text("Choose a folder to keep it indexed, or import individual files into Lilt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Choose files", action: model.importAudio)
                        .buttonStyle(.bordered)
                    Button("Add Folder", action: model.addLocalFolder)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190)
    }
}

private struct LocalCollectionCard: View {
    let collection: LocalMediaCollection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkView(url: collection.artworkURL, title: collection.title, size: 150)
                    Image(systemName: collection.kind.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.62), in: Circle())
                        .padding(8)
                }
                Text(collection.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(collection.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LocalCollectionDetailView: View {
    @ObservedObject var model: AppModel
    let collection: LocalMediaCollection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                ArtworkView(url: collection.artworkURL, title: collection.title, size: 116)
                VStack(alignment: .leading, spacing: 8) {
                    Text(collection.kind.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(collection.title)
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    Text(collection.subtitle)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(action: playAll) {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(collection.tracks.isEmpty)
                        Button(action: shuffle) {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(collection.tracks.isEmpty)
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            Divider().opacity(0.45)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if collection.tracks.isEmpty {
                        Text("No playable audio files found in this folder.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        ForEach(collection.tracks) { track in
                            TrackListRow(
                                track: track,
                                model: model,
                                player: model.player,
                                downloads: model.downloads,
                                onPlay: { model.play(track, queue: collection.tracks) }
                            )
                            Divider().opacity(0.35)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 760, height: 620)
        .background(BitChordBackground())
    }

    private func playAll() {
        guard let first = collection.tracks.first else { return }
        model.play(first, queue: collection.tracks)
    }

    private func shuffle() {
        model.playShuffled(collection.tracks)
    }
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Listening History")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("Most recent first · synced with YouTube Music")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.loadHistory) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.historyLoading)
                Button {
                    model.showHistory = false
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(28)

            Divider().opacity(0.4)

            if model.historyLoading && model.historyTracks.isEmpty {
                ProgressView("Loading your listening history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.historyError, model.historyTracks.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.purple)
                    Text(error)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Button("Try Again", action: model.loadHistory)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.historyTracks) { track in
                            TrackListRow(
                                track: track,
                                model: model,
                                player: model.player,
                                downloads: model.downloads,
                                onPlay: { model.play(track, queue: model.historyTracks) }
                            )
                            Divider().opacity(0.35)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .background(BitChordBackground())
        .onAppear {
            if model.historyTracks.isEmpty && !model.historyLoading { model.loadHistory() }
        }
        .sheet(item: $model.playlistTrack) { track in
            PlaylistPickerView(model: model, track: track)
        }
    }
}

private struct NewPlaylistView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var privacy: PlaylistPrivacy = .privatePlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("New Playlist")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Create it directly in your YouTube Music library")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.playlistActionInFlight { ProgressView().controlSize(.small) }
                Button {
                    model.showCreatePlaylist = false
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.playlistActionInFlight)
            }
            .padding(24)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("NAME")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.tertiary)
                    TextField("Playlist name", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("PRIVACY")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.tertiary)
                    Picker("Privacy", selection: $privacy) {
                        ForEach(PlaylistPrivacy.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                HStack {
                    Button("Cancel") {
                        model.showCreatePlaylist = false
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.playlistActionInFlight)
                    Spacer()
                    Button(action: create) {
                        Label("Create Playlist", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(cleanTitle.isEmpty || model.playlistActionInFlight)
                }
            }
            .padding(24)
        }
        .frame(width: 500)
        .background(BitChordBackground())
    }

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        guard !cleanTitle.isEmpty else { return }
        model.createPlaylist(title: cleanTitle, privacy: privacy, seededWith: nil)
    }
}

private struct EmptyLibrary: View {
    let youtubeSignedIn: Bool
    let onSignIn: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.purple)
                .padding(.bottom, 4)
            Text(youtubeSignedIn ? "Your library is empty" : "Connect your library")
                .font(.system(size: 21, weight: .bold, design: .rounded))
            Text(youtubeSignedIn
                 ? "No YouTube Music collections or local audio files were found."
                 : "Sign in for your YouTube Music playlists, or add audio files from this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                if !youtubeSignedIn {
                    Button("Sign in", action: onSignIn)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                }
                Button("Choose files", action: onImport)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CollectionDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var downloads: DownloadManager
    @ObservedObject private var playbackSettings: PlaybackSettings
    @StateObject private var albumCanvas: AlbumCanvasController
    let item: BrowseItem
    @Environment(\.dismiss) private var dismiss
    @State private var showRename = false
    @State private var renameTitle = ""
    @State private var showDeleteConfirmation = false

    init(model: AppModel, item: BrowseItem) {
        self.model = model
        self.item = item
        _downloads = ObservedObject(wrappedValue: model.downloads)
        _playbackSettings = ObservedObject(wrappedValue: model.playbackSettings)
        _albumCanvas = StateObject(wrappedValue: AlbumCanvasController(
            repository: model.canvasRepository,
            clipCache: model.canvasClipCache
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 22) {
                ZStack {
                    ArtworkView(url: item.artworkURL, title: item.title, size: 132)
                    if let artwork = albumCanvas.artwork {
                        CanvasVideoView(artwork: artwork, onReady: albumCanvas.markRendered)
                            .frame(width: 132, height: 132)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .opacity(albumCanvas.rendered ? 1 : 0)
                            .animation(.easeOut(duration: 0.28), value: albumCanvas.rendered)
                    }
                }
                .frame(width: 132, height: 132)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.kind.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                    Text(model.title(for: item))
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .lineLimit(2)
                    Text(item.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let first = model.browseTracks.first {
                        HStack(spacing: 10) {
                            if model.player.isLoading(first) {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading…")
                                }
                                .foregroundStyle(.secondary)
                            } else {
                                Button {
                                    model.play(first, queue: model.browseTracks)
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.purple)
                            }

                            Button {
                                model.playShuffled(model.browseTracks)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                downloads.enqueue(model.browseTracks, from: item)
                            } label: {
                                Label(downloadButtonTitle, systemImage: downloadButtonIcon)
                            }
                            .buttonStyle(.bordered)
                            .disabled(downloadableTracks.isEmpty)
                        }
                        .padding(.top, 6)
                    }
                }
                Spacer()
                if !model.browseTracks.isEmpty || item.kind == .playlist || model.selectedPlaylistOwned {
                    Menu {
                        if !model.browseTracks.isEmpty {
                            Button { model.player.playNext(model.browseTracks) } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            Button { model.player.addToQueue(model.browseTracks) } label: {
                                Label("Add to Queue", systemImage: "text.badge.plus")
                            }
                        }
                        if item.kind == .playlist {
                            if !model.browseTracks.isEmpty { Divider() }
                            Button { model.togglePinned(item) } label: {
                                Label(
                                    model.isPinned(item) ? "Unpin Playlist" : "Pin Playlist",
                                    systemImage: model.isPinned(item) ? "pin.slash" : "pin"
                                )
                            }
                        }
                        if model.selectedPlaylistOwned {
                            Divider()
                            Button {
                                renameTitle = model.title(for: item)
                                showRename = true
                            } label: {
                                Label("Rename Playlist…", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete Playlist…", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(model.playlistActionInFlight)
                }
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(28)

            Divider().opacity(0.4)

            if model.browseLoading {
                ProgressView("Loading from YouTube Music…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.browseError {
                InlineNotice(text: error, actionTitle: "Retry") {
                    model.openBrowseItem(item)
                }
                .padding(28)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.browseTracks) { track in
                            TrackListRow(
                                track: track,
                                model: model,
                                player: model.player,
                                downloads: downloads,
                                onPlay: { model.play(track, queue: model.browseTracks) }
                            )
                            Divider().opacity(0.35)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(minWidth: 720, minHeight: 580)
        .background(BitChordBackground())
        .task(id: albumCanvasRequestKey) {
            albumCanvas.load(album: model.title(for: item), artist: albumArtist, allowed: albumCanvasAllowed)
        }
        .sheet(item: $model.playlistTrack) { track in
            PlaylistPickerView(model: model, track: track)
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Playlist name", text: $renameTitle)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.renameSelectedPlaylist(to: renameTitle) }
                .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The new name will be saved to YouTube Music.")
        }
        .confirmationDialog(
            "Delete “\(model.title(for: item))”?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) { model.deleteSelectedPlaylist() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the playlist from your YouTube Music account.")
        }
    }

    private var downloadableTracks: [Track] {
        model.browseTracks.filter {
            $0.videoID != nil && !downloads.isDownloaded($0) && downloads.state(for: $0) == nil
        }
    }

    private var albumArtist: String {
        model.browseTracks.first?.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? item.subtitle.components(separatedBy: " • ").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
    }

    private var albumCanvasAllowed: Bool {
        item.kind == .album && playbackSettings.animatedCanvas &&
            (!playbackSettings.networkIsMetered || playbackSettings.canvasOverMetered)
    }

    private var albumCanvasRequestKey: String {
        "\(item.id)|\(model.title(for: item))|\(albumArtist)|\(albumCanvasAllowed)"
    }

    private var downloadButtonTitle: String {
        if model.browseTracks.contains(where: downloads.isDownloaded) && downloadableTracks.isEmpty {
            return "Downloaded"
        }
        if model.browseTracks.contains(where: { downloads.state(for: $0) != nil }) {
            return "Downloading"
        }
        return "Download"
    }

    private var downloadButtonIcon: String {
        downloadableTracks.isEmpty ? "checkmark.circle.fill" : "arrow.down.circle"
    }
}

private struct PlaylistPickerView: View {
    @ObservedObject var model: AppModel
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var title = ""
    @State private var privacy: PlaylistPrivacy = .privatePlaylist

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ArtworkView(url: track.artworkURL, title: track.title, size: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add to playlist")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("\(track.title) · \(track.artist)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if model.playlistActionInFlight {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.playlistTrack = nil
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.playlistActionInFlight)
            }
            .padding(24)

            Divider().opacity(0.4)

            if creating {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Playlist name", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                    Picker("Privacy", selection: $privacy) {
                        ForEach(PlaylistPrivacy.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Button("Cancel") { creating = false }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button(action: create) {
                            Label("Create and Add", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.playlistActionInFlight)
                    }
                }
                .padding(20)
                .background(.purple.opacity(0.08))
            } else {
                Button { creating = true } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.purple.opacity(0.16))
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.purple)
                        }
                        .frame(width: 46, height: 46)
                        Text("New playlist")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .disabled(model.playlistActionInFlight)
            }

            Divider().opacity(0.4)

            if model.playlistsLoading && model.userPlaylists.isEmpty {
                ProgressView("Loading your playlists…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.userPlaylists.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 28))
                        .foregroundStyle(.purple)
                    Text("No playlists yet")
                        .font(.headline)
                    Text("Create one above and this track will be added immediately.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.userPlaylists) { playlist in
                            Button { model.add(track, to: playlist) } label: {
                                HStack(spacing: 13) {
                                    ArtworkView(url: playlist.artworkURL, title: playlist.title, size: 50)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(playlist.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .lineLimit(1)
                                        Text(playlist.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.purple)
                                }
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.playlistActionInFlight)
                            Divider().opacity(0.3)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: 520, height: 560)
        .background(BitChordBackground())
        .interactiveDismissDisabled(model.playlistActionInFlight)
        .onAppear { model.loadUserPlaylists() }
    }

    private func create() {
        model.createPlaylist(title: title, privacy: privacy, seededWith: track)
    }
}

struct DownloadsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var downloads: DownloadManager
    @ObservedObject private var settings: PlaybackSettings
    @State private var selectedCollection: DownloadCollectionRecord?

    init(model: AppModel) {
        self.model = model
        _downloads = ObservedObject(wrappedValue: model.downloads)
        _settings = ObservedObject(wrappedValue: model.playbackSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Downloads")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text(downloads.saved.isEmpty
                         ? "Music saved for offline listening"
                         : "\(downloads.saved.count) \(downloads.saved.count == 1 ? "track" : "tracks") available offline")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(DownloadQuality.allCases) { quality in
                        Button {
                            downloads.preferredQuality = quality
                        } label: {
                            if downloads.preferredQuality == quality {
                                Label("\(quality.title) — \(quality.detail)", systemImage: "checkmark")
                            } else {
                                Text("\(quality.title) — \(quality.detail)")
                            }
                        }
                    }
                } label: {
                    Label(downloads.preferredQuality.title, systemImage: downloads.preferredQuality.systemImage)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Quality for new downloads")

                Menu {
                    ForEach(1...4, id: \.self) { count in
                        Button {
                            downloads.maximumParallelDownloads = count
                        } label: {
                            if downloads.maximumParallelDownloads == count {
                                Label("\(count) at a time", systemImage: "checkmark")
                            } else {
                                Text("\(count) at a time")
                            }
                        }
                    }
                } label: {
                    Label("\(downloads.maximumParallelDownloads)", systemImage: "square.stack.3d.up.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Parallel downloads")

                Button(action: downloads.openDownloadsFolder) {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 34)
            .padding(.top, 30)
            .padding(.bottom, 24)

            if !settings.downloadsAllowedNow {
                HStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 34, height: 34)
                        .background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("New downloads are paused on this network")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Existing files still play offline. Connect through an unmetered network or change the download policy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Settings") { model.section = .settings }
                        .buttonStyle(.bordered)
                }
                .padding(14)
                .background(.orange.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.orange.opacity(0.2), lineWidth: 1)
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if !downloads.queueItems.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            DownloadBatchHeader(downloads: downloads)
                            VStack(spacing: 8) {
                                ForEach(downloads.queueItems) { item in
                                    DownloadQueueRow(downloads: downloads, item: item)
                                }
                            }
                        }
                    }

                    if !downloads.collections.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Downloaded Collections")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 12) {
                                    ForEach(downloads.collections) { collection in
                                        Button {
                                            selectedCollection = collection
                                        } label: {
                                            DownloadCollectionCard(downloads: downloads, collection: collection)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button("Forget Collection") { downloads.forget(collection) }
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .scrollIndicators(.hidden)
                        }
                    }

                    if !downloads.saved.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(downloads.collections.isEmpty ? "On this Mac" : "All Downloaded Songs")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                            LazyVStack(spacing: 0) {
                                ForEach(downloads.saved) { record in
                                    TrackListRow(
                                        track: record.playableTrack,
                                        model: model,
                                        player: model.player,
                                        downloads: downloads,
                                        onPlay: {
                                            model.play(record.playableTrack, queue: downloads.savedTracks)
                                        }
                                    )
                                    .contextMenu {
                                        Button("Show in Finder") { downloads.reveal(record) }
                                        Divider()
                                        Button("Move to Trash", role: .destructive) {
                                            _ = downloads.remove(record)
                                        }
                                    }
                                    Divider().opacity(0.35)
                                }
                            }
                        }
                    }

                    if downloads.saved.isEmpty && downloads.queueItems.isEmpty {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle().fill(.purple.opacity(0.14)).frame(width: 88, height: 88)
                                Image(systemName: "arrow.down.to.line.compact")
                                    .font(.system(size: 32, weight: .medium))
                                    .foregroundStyle(.purple)
                            }
                            Text("Nothing downloaded yet")
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                            Text("Right-click a song or download an entire playlist.\nFinished tracks stay here and play without the network.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 330)
                    }
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(item: $selectedCollection) { collection in
            DownloadedCollectionDetail(model: model, downloads: downloads, collection: collection)
        }
    }
}

private struct DownloadBatchHeader: View {
    @ObservedObject var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Downloading")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    if let summary = downloads.sessionSummary {
                        Text(summaryText(summary))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if downloads.failedCount > 0 {
                    Button("Retry Failed", action: downloads.retryFailed)
                        .buttonStyle(.bordered)
                    Button("Clear", action: downloads.clearFailures)
                        .buttonStyle(.borderless)
                }
                if downloads.queueItems.contains(where: { item in
                    if case .failed = item.activity { return false }
                    return true
                }) {
                    Button("Cancel All", action: downloads.cancelAllActive)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            if let summary = downloads.sessionSummary {
                ProgressView(value: summary.fraction)
                    .progressViewStyle(.linear)
                    .tint(.pink)
            }
        }
    }

    private func summaryText(_ summary: DownloadSessionSummary) -> String {
        var parts = ["\(summary.completed) of \(summary.total) finished"]
        if summary.running > 0 { parts.append("\(summary.running) active") }
        if summary.waiting > 0 { parts.append("\(summary.waiting) waiting") }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        return parts.joined(separator: " · ")
    }
}

private struct DownloadCollectionCard: View {
    @ObservedObject var downloads: DownloadManager
    let collection: DownloadCollectionRecord

    var body: some View {
        HStack(spacing: 13) {
            ArtworkView(url: collection.artworkURL, title: collection.title, size: 82)
            VStack(alignment: .leading, spacing: 6) {
                Text(collection.kind.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.pink)
                Text(collection.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(status.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: downloads.progress(for: collection))
                    .progressViewStyle(.linear)
                    .tint(status.completed == status.total ? .green : .purple)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(width: 285, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var status: DownloadCollectionStatus {
        downloads.status(for: collection)
    }
}

private struct DownloadedCollectionDetail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var downloads: DownloadManager
    let collection: DownloadCollectionRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                ArtworkView(url: collection.artworkURL, title: collection.title, size: 104)
                VStack(alignment: .leading, spacing: 7) {
                    Text("DOWNLOADED \(collection.kind.uppercased())")
                        .font(.caption.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(.pink)
                    Text(collection.title)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Text(status.statusText)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            guard let first = tracks.first else { return }
                            model.play(first, queue: tracks)
                        } label: {
                            Label("Play Downloaded", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .disabled(tracks.isEmpty)
                        Button {
                            model.playShuffled(tracks)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(tracks.isEmpty)
                    }
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            Divider().opacity(0.4)

            if tracks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.purple)
                    Text("No Finished Songs")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("The collection is remembered, but no tracks have finished downloading yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(records) { record in
                            TrackListRow(
                                track: record.playableTrack,
                                model: model,
                                player: model.player,
                                downloads: downloads,
                                onPlay: { model.play(record.playableTrack, queue: tracks) }
                            )
                            .contextMenu {
                                Button("Show in Finder") { downloads.reveal(record) }
                            }
                            Divider().opacity(0.35)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: 680, height: 590)
        .background(BitChordBackground())
    }

    private var records: [DownloadRecord] { downloads.records(in: collection) }
    private var tracks: [Track] { records.map(\.playableTrack) }
    private var status: DownloadCollectionStatus { downloads.status(for: collection) }
}

private struct DownloadQueueRow: View {
    @ObservedObject var downloads: DownloadManager
    let item: DownloadQueueItem

    var body: some View {
        HStack(spacing: 13) {
            ArtworkView(url: item.track.artworkURL, title: item.track.title, size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(item.track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .downloading(let progress) = item.activity {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.purple)
                        .frame(maxWidth: 360)
                }
                Text(item.activity.statusText)
                    .font(.caption2)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer()
            if isFailure {
                Button("Retry") { downloads.retry(item.track) }
                    .buttonStyle(.bordered)
                Button { downloads.dismissFailure(item.track) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Button { downloads.cancel(item.track) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel download")
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var isFailure: Bool {
        if case .failed = item.activity { return true }
        return false
    }
}

private struct DownloadMenuAction: View {
    @ObservedObject var downloads: DownloadManager
    let track: Track

    var body: some View {
        if track.videoID != nil, !track.isLocal {
            Button(action: perform) {
                Label(title, systemImage: icon)
            }
            .disabled(isDisabled)
        }
    }

    private func perform() {
        if case .failed = downloads.state(for: track) {
            downloads.retry(track)
        } else {
            downloads.enqueue(track)
        }
    }

    private var title: String {
        if downloads.isDownloaded(track) { return "Downloaded" }
        switch downloads.state(for: track) {
        case .queued: return "Queued for Download"
        case .downloading(let value): return "Downloading \(Int(value * 100))%"
        case .failed: return "Retry Download"
        case nil: return "Download"
        }
    }

    private var icon: String {
        if downloads.isDownloaded(track) { return "checkmark.circle.fill" }
        if case .failed = downloads.state(for: track) { return "arrow.clockwise" }
        return "arrow.down.circle"
    }

    private var isDisabled: Bool {
        if downloads.isDownloaded(track) { return true }
        switch downloads.state(for: track) {
        case .queued, .downloading: return true
        case .failed, nil: return false
        }
    }
}

private struct TrackQueueMenuActions: View {
    @ObservedObject var player: PlaybackController
    let track: Track

    var body: some View {
        Button {
            player.playNext(track)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            player.addToQueue(track)
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }
    }
}

private struct TrackNavigationMenuActions: View {
    @ObservedObject var model: AppModel
    let track: Track
    var beforeOpen: () -> Void = {}

    private var linkedTrack: Track { model.trackWithResolvedLinks(track) }

    var body: some View {
        Group {
            if track.videoID != nil {
                if linkedTrack.albumBrowseID != nil {
                    Button {
                        beforeOpen()
                        model.openAlbum(for: linkedTrack)
                    } label: {
                        Label("Open Album", systemImage: "square.stack")
                    }
                } else if model.isResolvingLinks(for: track) {
                    Button(action: {}) {
                        Label("Finding Album…", systemImage: "hourglass")
                    }
                    .disabled(true)
                }

                if linkedTrack.artistBrowseID != nil {
                    Button {
                        beforeOpen()
                        model.openArtist(for: linkedTrack)
                    } label: {
                        Label("Open Artist", systemImage: "person.crop.circle")
                    }
                } else if model.isResolvingLinks(for: track) {
                    Button(action: {}) {
                        Label("Finding Artist…", systemImage: "hourglass")
                    }
                    .disabled(true)
                }

                if let url = track.youtubeURL, !track.isLocal {
                    ShareLink(item: url, subject: Text(track.title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            model.resolveTrackLinksIfNeeded(track)
        }
    }
}

private struct YouTubeTrackMenuActions: View {
    @ObservedObject var model: AppModel
    let track: Track

    var body: some View {
        if track.videoID != nil, !track.isLocal {
            Button { model.toggleLike(track) } label: {
                Label(
                    model.likeStatus(for: track) == .like ? "Remove Like" : "Like",
                    systemImage: model.likeStatus(for: track) == .like ? "heart.slash" : "heart"
                )
            }
            .disabled(isPending)
            Button { model.toggleDislike(track) } label: {
                Label(
                    model.likeStatus(for: track) == .dislike ? "Remove Dislike" : "Dislike",
                    systemImage: "hand.thumbsdown"
                )
            }
            .disabled(isPending)
            Button { model.presentPlaylistPicker(for: track) } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }
            if model.selectedPlaylistOwned, track.setVideoID != nil {
                Divider()
                Button(role: .destructive) { model.removeFromSelectedPlaylist(track) } label: {
                    Label("Remove from This Playlist", systemImage: "minus.circle")
                }
                .disabled(model.playlistActionInFlight)
            }
        }
    }

    private var isPending: Bool {
        guard let videoID = track.videoID else { return false }
        return model.ratingInFlight.contains(videoID)
    }
}

private struct TrackListRow: View {
    let track: Track
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlaybackController
    @ObservedObject var downloads: DownloadManager
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 14) {
                ArtworkView(url: track.artworkURL, title: track.title, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.system(size: 13, weight: .semibold))
                    Text(track.artist).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let album = track.album { Text(album).font(.caption).foregroundStyle(.tertiary) }
                if !track.durationText.isEmpty {
                    Text(track.durationText).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if !track.isLocal {
                    downloadAccessory
                }
                if player.isLoading(track) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: player.isCurrent(track) && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                        .frame(width: 28, height: 28)
                        .foregroundStyle(player.isCurrent(track) ? .white : .purple)
                        .background(player.isCurrent(track) ? Color.purple : Color.clear, in: Circle())
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if track.isLocal {
                Button { model.revealLocalTrack(track) } label: {
                    Label("Show in Finder", systemImage: "finder")
                }
                if track.localFolderID == nil {
                    Button(role: .destructive) { model.removeLocalTrack(track) } label: {
                        Label("Remove Imported Copy", systemImage: "trash")
                    }
                }
                Divider()
            } else {
                YouTubeTrackMenuActions(model: model, track: track)
                Divider()
            }
            TrackQueueMenuActions(player: player, track: track)
            if track.videoID != nil {
                Divider()
                TrackNavigationMenuActions(model: model, track: track)
            }
            if !track.isLocal {
                Divider()
                DownloadMenuAction(downloads: downloads, track: track)
            }
        }
    }

    @ViewBuilder
    private var downloadAccessory: some View {
        if downloads.isDownloaded(track) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.green)
                .help("Available offline")
        } else {
            switch downloads.state(for: track) {
            case .queued:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            case .downloading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            case nil:
                EmptyView()
            }
        }
    }
}

struct PlaybackSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: PlaybackSettings
    @ObservedObject var player: PlaybackController
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var sources: SourceModuleManager
    @ObservedObject var scrobbling: ScrobblingManager
    @ObservedObject var lyricsSettings: LyricsSettings
    @ObservedObject var equalizer: EqualizerSettings
    @State private var editingSource = false
    @State private var editingSpotifyCanvas = false
    @State private var connectingScrobbler: ScrobblingConnection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Settings")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Appearance, streaming and playback behavior")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(
                        title: "Appearance",
                        subtitle: "Let the current record shape the player without sacrificing contrast."
                    )
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.indigo)
                                .frame(width: 34, height: 34)
                                .background(.indigo.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Theme")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Follow macOS or keep Lilt light or dark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 18)
                            Picker("Theme", selection: $settings.themeMode) {
                                ForEach(AppThemeMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 216)
                        }
                        .padding(16)

                        Divider().padding(.leading, 64)

                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [.indigo, .pink, .orange],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                Image(systemName: "paintpalette.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Artwork-driven theme")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Build the player background, progress and glass tint from each cover")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $settings.dynamicArtworkTheme)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(16)

                        Divider().padding(.leading, 64)

                        HStack(spacing: 14) {
                            Image(systemName: "figure.walk.motion")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.cyan)
                                .frame(width: 34, height: 34)
                                .background(.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Reduce animation")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Keep artwork colors but stop the slow background drift")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $settings.reduceAnimation)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(16)

                        Divider().padding(.leading, 64)

                        HStack(spacing: 14) {
                            Image(systemName: "camera.filters")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.mint)
                                .frame(width: 34, height: 34)
                                .background(.mint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Reduce dynamic blur")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Replace frosted glass and blurred color blooms with solid fills")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $settings.reduceDynamicBlur)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(16)

                        Divider().padding(.leading, 64)

                        HStack(spacing: 14) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.orange)
                                .frame(width: 34, height: 34)
                                .background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Full-bleed artwork")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Run the cover to the edges of the player column instead of a square sleeve")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $settings.fullBleedArtwork)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(16)

                        Divider().padding(.leading, 64)

                        HStack(spacing: 14) {
                            Image(systemName: "play.square.stack.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.pink)
                                .frame(width: 34, height: 34)
                                .background(.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Animated cover art")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Use matching Apple Music, TIDAL, community or Spotify motion artwork")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $settings.animatedCanvas)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(16)

                        if settings.animatedCanvas {
                            Divider().padding(.leading, 64)
                            HStack(spacing: 12) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(.orange)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Allow motion artwork on metered networks")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("Video loops can use substantially more data than a still cover")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: $settings.canvasOverMetered)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .transition(.opacity.combined(with: .move(edge: .top)))

                            Divider().padding(.leading, 64)

                            Button {
                                editingSpotifyCanvas = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "sparkles.tv.fill")
                                        .foregroundStyle(.green)
                                        .frame(width: 34)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Integrate Spotify Canvas")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Text(model.spotifyCanvasSettings.isConfigured
                                             ? "Connected · session stored in Keychain"
                                             : "Optional · use Spotify's original vertical clips")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(
                        title: "Audio Quality",
                        subtitle: "Lilt switches profiles automatically for hotspots and constrained networks."
                    )
                    VStack(spacing: 0) {
                        QualitySettingRow(
                            title: "Wi-Fi & Ethernet",
                            subtitle: "Unmetered connections",
                            selection: $settings.unmeteredQuality,
                            isActive: !settings.networkIsMetered
                        )
                        Divider().padding(.leading, 54)
                        QualitySettingRow(
                            title: "Metered & Hotspot",
                            subtitle: "Expensive or constrained connections",
                            selection: $settings.meteredQuality,
                            isActive: settings.networkIsMetered
                        )
                    }
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(spacing: 7) {
                        Circle()
                            .fill(settings.networkIsMetered ? Color.orange : Color.green)
                            .frame(width: 7, height: 7)
                        Text(settings.networkIsMetered ? "Metered profile is active" : "Wi-Fi & Ethernet profile is active")
                        Spacer()
                        Text("Current: \(settings.effectiveQuality.title)")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(
                        title: "Downloads",
                        subtitle: "Choose the permanent file quality and protect metered connections."
                    )
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            Image(systemName: downloads.preferredQuality.systemImage)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.purple)
                                .frame(width: 34, height: 34)
                                .background(.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Download Quality")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(downloads.preferredQuality.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                ForEach(DownloadQuality.allCases) { quality in
                                    Button {
                                        downloads.preferredQuality = quality
                                    } label: {
                                        if downloads.preferredQuality == quality {
                                            Label(quality.title, systemImage: "checkmark")
                                        } else {
                                            Text(quality.title)
                                        }
                                    }
                                }
                            } label: {
                                Text(downloads.preferredQuality.title)
                                    .font(.caption.weight(.semibold))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        .padding(16)

                        Divider().padding(.leading, 64)

                        HStack(spacing: 14) {
                            Image(systemName: "wifi")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(settings.downloadsAllowedNow ? .green : .orange)
                                .frame(width: 34, height: 34)
                                .background(
                                    (settings.downloadsAllowedNow ? Color.green : Color.orange).opacity(0.13),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 7) {
                                    Text("Unmetered networks only")
                                        .font(.system(size: 14, weight: .semibold))
                                    if settings.wifiOnlyDownloads && settings.networkIsMetered {
                                        Text("BLOCKING")
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundStyle(.orange)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(.orange.opacity(0.12), in: Capsule())
                                    }
                                }
                                Text(settings.wifiOnlyDownloads
                                     ? "Allow new transfers on Wi-Fi and Ethernet, but not expensive hotspots."
                                     : "Allow new transfers on metered and unmetered connections.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $settings.wifiOnlyDownloads)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(16)
                    }
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(
                        title: "Audio Sources",
                        subtitle: "Sources are tried in order. A miss is stepped over, so playback continues from the next catalogue."
                    )
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.pink)
                                .frame(width: 34, height: 34)
                                .background(.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("1  \(sources.displayName)")
                                    .font(.system(size: 14, weight: .semibold))
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(sourceStatusColor)
                                        .frame(width: 6, height: 6)
                                    Text(sources.health.statusLine)
                                }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if !sources.indexURLString.isEmpty {
                                Toggle("", isOn: Binding(
                                    get: { sources.enabled },
                                    set: sources.setEnabled
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }
                            Button(sources.indexURLString.isEmpty ? "Add" : "Edit") {
                                editingSource = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(16)

                        Divider().padding(.leading, 64)

                        HStack(spacing: 14) {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.pink)
                                .frame(width: 34, height: 34)
                                .background(.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("2  JioSaavn")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("High-quality AAC · up to 320 kbps · built in")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { sources.jioSaavnEnabled },
                                set: sources.setJioSaavnEnabled
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                        .padding(16)

                        Divider().padding(.leading, 64)

                        HStack(spacing: 14) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.red)
                                .frame(width: 34, height: 34)
                                .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("3  YouTube Music")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Full catalogue · playback fallback · always on")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Fallback")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                    }
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text(settings.effectiveQuality == .high
                         ? "High quality is active: the module and JioSaavn race YouTube without delaying playback. A better late stream is aligned and blended in while the song keeps playing."
                         : "The active network profile caps quality below High, so replacement-source lookup is paused to respect the data limit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(
                        title: "Song Cache",
                        subtitle: "Played tracks are kept on disk for instant replays and reliable seeking. Oldest entries leave first."
                    )
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 14) {
                                Image(systemName: "internaldrive.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.purple)
                                    .frame(width: 34, height: 34)
                                    .background(.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Cache limit")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("\(Self.formatBytes(model.audioCacheSnapshot.usedBytes)) used by \(model.audioCacheSnapshot.fileCount) song\(model.audioCacheSnapshot.fileCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Self.formatBytes(settings.audioCacheLimitBytes))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(settings.audioCacheLimitBytes) / Self.gibibyte },
                                    set: { settings.audioCacheLimitBytes = Int64(($0 * Self.gibibyte).rounded()) }
                                ),
                                in: 0.5...10,
                                step: 0.5
                            )
                            .tint(.purple)
                            HStack {
                                Text("512 MB")
                                Spacer()
                                Text("10 GB")
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        .padding(16)

                        Divider().padding(.leading, 64)

                        Button(action: model.clearAudioCache) {
                            HStack(spacing: 14) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.red)
                                    .frame(width: 34, height: 34)
                                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Clear Song Cache")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text("Downloads and imported music are not removed")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.audioCacheBusy {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(Self.formatBytes(model.audioCacheSnapshot.usedBytes))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.audioCacheBusy || model.audioCacheSnapshot.fileCount == 0)
                        .padding(16)
                    }
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(
                        title: "Playback",
                        subtitle: "Changes apply immediately to the current track."
                    )
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            Image(systemName: "infinity")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.purple)
                                .frame(width: 34, height: 34)
                                .background(.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("AutoPlay")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Keep the queue going with YouTube Music radio recommendations.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if player.autoplayLoading {
                                ProgressView().controlSize(.small)
                            }
                            Toggle("", isOn: $settings.autoplay)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(16)

                        if settings.autoplay {
                            Divider().padding(.leading, 64)
                            HStack(spacing: 14) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.cyan)
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Avoid repeated suggestions")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("Remember recommendations for this listening session.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: $settings.dontRepeatSuggestions)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(spacing: 14) {
                        Image(systemName: "waveform.path.ecg.rectangle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.cyan)
                            .frame(width: 34, height: 34)
                            .background(.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Automix")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Off by default. When enabled, Lilt beat-matches the next song without skipping its opening.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if settings.smartFadeEnabled {
                                Text(player.automixStatus.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(player.isTransitioning ? .pink : .cyan)
                                    .padding(.top, 2)
                            }
                        }
                        Spacer()
                        Toggle("Automix", isOn: $settings.smartFadeEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Automix")
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(spacing: 14) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 34, height: 34)
                            .background(.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Playback Speed")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Saved as the default for every track and restored on the next launch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            ForEach(PlaybackSettings.supportedRates, id: \.self) { rate in
                                Button {
                                    settings.playbackSpeed = rate
                                } label: {
                                    if settings.playbackSpeed == rate {
                                        Label(Self.speedLabel(rate), systemImage: "checkmark")
                                    } else {
                                        Text(Self.speedLabel(rate))
                                    }
                                }
                            }
                        } label: {
                            Text(Self.speedLabel(settings.playbackSpeed))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .frame(minWidth: 40)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(spacing: 14) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.green)
                            .frame(width: 34, height: 34)
                            .background(.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Volume Control")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Show the app volume slider in Now Playing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { !settings.hideVolumeBar },
                                set: { settings.hideVolumeBar = !$0 }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if !settings.smartFadeEnabled {
                        VStack(spacing: 12) {
                        HStack(spacing: 14) {
                            Image(systemName: "waveform.path")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.pink)
                                .frame(width: 34, height: 34)
                                .background(.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Crossfade")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Preloads the next song and blends both tracks with a constant-power curve.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(settings.crossfadeSeconds == 0 ? "Off" : "\(settings.crossfadeSeconds)s")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(player.isTransitioning ? .pink : .secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.crossfadeSeconds) },
                                set: { settings.crossfadeSeconds = Int($0.rounded()) }
                            ),
                            in: 0...12,
                            step: 1
                        )
                        .tint(.pink)
                        HStack {
                            Text("Gapless")
                            Spacer()
                            Text("12 seconds")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    HStack(spacing: 14) {
                        Image(systemName: "forward.end.alt.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.purple)
                            .frame(width: 34, height: 34)
                            .background(.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Skip Silence")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Skips dead air longer than one second while preserving short musical pauses.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.skipSilence)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(spacing: 14) {
                        Image(systemName: "hifispeaker.2.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.cyan)
                            .frame(width: 34, height: 34)
                            .background(.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Spatial Audio")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Widens stereo and adds delayed low-passed crossfeed in Lilt's PCM pipeline.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.spatialAudio)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(spacing: 14) {
                        Image(systemName: "music.note.tv.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 34, height: 34)
                            .background(.red.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Prefer catalogue audio")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Replace music-video uploads with their matching album release before playback and download.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.convertVideoToAudio)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack(spacing: 14) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.pink)
                            .frame(width: 34, height: 34)
                            .background(.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Stats for Nerds")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Show the measured codec, bitrate and output format on the player.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.showNerdStats)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(16)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                EqualizerSettingsCard(
                    equalizer: equalizer,
                    isAppliedToCurrentTrack: player.equalizerActive
                )

                if let info = player.streamInfo {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsSectionTitle(
                            title: "Current Stream",
                            subtitle: "The format selected for the track playing now."
                        )
                        HStack(spacing: 12) {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .foregroundStyle(.pink)
                            Text(info.technicalDescription ?? info.shortDescription)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                            Spacer()
                            if let sourceName = info.sourceName {
                                Text(sourceName)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(16)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(
                        title: "Synced Lyrics",
                        subtitle: "Seven providers race in parallel while your priority order still decides which answer wins."
                    )
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            Image(systemName: "quote.bubble.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.purple)
                                .frame(width: 34, height: 34)
                                .background(.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Time-synced lyrics")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Load lyrics automatically for every track")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { lyricsSettings.enabled },
                                set: {
                                    lyricsSettings.enabled = $0
                                    player.reloadLyrics()
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                        .padding(16)

                        if lyricsSettings.enabled {
                            Divider().padding(.leading, 64)
                            HStack(spacing: 14) {
                                Image(systemName: "textformat.abc.dottedunderline")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.pink)
                                    .frame(width: 34, height: 34)
                                    .background(.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Prefer word timing")
                                        .font(.system(size: 14, weight: .semibold))
                                    Text("Keep a line-synced fallback while waiting for a syllable-timed source")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { lyricsSettings.prioritizeWordTiming },
                                    set: {
                                        lyricsSettings.prioritizeWordTiming = $0
                                        player.reloadLyrics()
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }
                            .padding(16)

                            ForEach(Array(lyricsSettings.sourceOrder.enumerated()), id: \.element) { index, source in
                                Divider().padding(.leading, 64)
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22, height: 22)
                                        .background(Color.primary.opacity(0.06), in: Circle())
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 7) {
                                            Text(source.title)
                                                .font(.system(size: 14, weight: .semibold))
                                            if source.supportsWordTiming {
                                                Text("WORD")
                                                    .font(.system(size: 8, weight: .black, design: .rounded))
                                                    .foregroundStyle(.pink)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(.pink.opacity(0.12), in: Capsule())
                                            }
                                        }
                                        Text(source.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    HStack(spacing: 3) {
                                        Button {
                                            lyricsSettings.move(source, by: -1)
                                            player.reloadLyrics()
                                        } label: {
                                            Image(systemName: "chevron.up")
                                        }
                                        .disabled(index == 0)
                                        Button {
                                            lyricsSettings.move(source, by: 1)
                                            player.reloadLyrics()
                                        } label: {
                                            Image(systemName: "chevron.down")
                                        }
                                        .disabled(index == lyricsSettings.sourceOrder.count - 1)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    Toggle("", isOn: Binding(
                                        get: { lyricsSettings.isEnabled(source) },
                                        set: {
                                            lyricsSettings.setEnabled(source, enabled: $0)
                                            player.reloadLyrics()
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .opacity(lyricsSettings.isEnabled(source) ? 1 : 0.48)
                            }
                        }
                    }
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    HStack {
                        Text("Only the track title, artist, album and duration are sent to enabled providers.")
                        Spacer()
                        Button("Reset Sources") {
                            lyricsSettings.resetSources()
                            player.reloadLyrics()
                        }
                        .buttonStyle(.link)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(
                        title: "Scrobbling",
                        subtitle: "Send listened tracks to your own Last.fm and ListenBrainz profiles. Credentials stay in this Mac's Keychain."
                    )
                    VStack(spacing: 0) {
                        ScrobblingServiceRow(
                            icon: "brain.head.profile",
                            color: .orange,
                            title: "ListenBrainz",
                            subtitle: scrobbling.listenBrainzConnected
                                ? "Connected as \(scrobbling.listenBrainzUsername)"
                                : "Connect with a ListenBrainz user token",
                            isConnected: scrobbling.listenBrainzConnected,
                            isEnabled: Binding(
                                get: { scrobbling.listenBrainzEnabled },
                                set: { scrobbling.listenBrainzEnabled = $0 }
                            ),
                            onConnect: { connectingScrobbler = .listenBrainz },
                            onDisconnect: scrobbling.disconnectListenBrainz
                        )
                        Divider().padding(.leading, 64)
                        ScrobblingServiceRow(
                            icon: "dot.radiowaves.left.and.right",
                            color: .red,
                            title: "Last.fm",
                            subtitle: scrobbling.lastFMConnected
                                ? "Connected as \(scrobbling.lastFMUsername)"
                                : "Connect with your Last.fm API credentials",
                            isConnected: scrobbling.lastFMConnected,
                            isEnabled: Binding(
                                get: { scrobbling.lastFMEnabled },
                                set: { scrobbling.lastFMEnabled = $0 }
                            ),
                            onConnect: { connectingScrobbler = .lastFM },
                            onDisconnect: scrobbling.disconnectLastFM
                        )

                        if scrobbling.lastFMConnected {
                            Divider().padding(.leading, 64)
                            ScrobblingToggleRow(
                                icon: "clock.arrow.circlepath",
                                title: "Scrobble tracks",
                                subtitle: "Add qualified plays to your Last.fm timeline",
                                isOn: $scrobbling.lastFMScrobbleEnabled
                            )
                            Divider().padding(.leading, 64)
                            ScrobblingToggleRow(
                                icon: "waveform",
                                title: "Now Playing",
                                subtitle: "Show the active track on Last.fm immediately",
                                isOn: $scrobbling.lastFMNowPlayingEnabled
                            )
                            .disabled(!scrobbling.lastFMScrobbleEnabled)
                            .opacity(scrobbling.lastFMScrobbleEnabled ? 1 : 0.48)
                        }
                    }
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if scrobbling.lastFMConnected || scrobbling.listenBrainzConnected {
                        VStack(spacing: 14) {
                            ScrobblingSliderRow(
                                title: "Minimum song length",
                                value: "\(scrobbling.minimumSongDuration)s",
                                subtitle: "Shorter tracks are never scrobbled",
                                sliderValue: Binding(
                                    get: { Double(scrobbling.minimumSongDuration) },
                                    set: { scrobbling.minimumSongDuration = Int($0.rounded()) }
                                ),
                                range: 15...120,
                                step: 5
                            )
                            Divider()
                            ScrobblingSliderRow(
                                title: "Listen threshold",
                                value: "\(Int((scrobbling.delayPercent * 100).rounded()))%",
                                subtitle: "How much of a track must be heard",
                                sliderValue: $scrobbling.delayPercent,
                                range: 0.1...1,
                                step: 0.1
                            )
                            Divider()
                            ScrobblingSliderRow(
                                title: "Maximum delay",
                                value: "\(scrobbling.maximumDelay)s",
                                subtitle: "The threshold never waits longer than this",
                                sliderValue: Binding(
                                    get: { Double(scrobbling.maximumDelay) },
                                    set: { scrobbling.maximumDelay = Int($0.rounded()) }
                                ),
                                range: 30...300,
                                step: 10
                            )
                        }
                        .padding(16)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    if let status = scrobbling.status {
                        HStack(spacing: 7) {
                            Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            Text(status.message)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.isError ? .red : .green)
                        .padding(.horizontal, 4)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    SettingsSectionTitle(
                        title: "Your Data",
                        subtitle: "A portable JSON backup compatible with the Android app."
                    )
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.green)
                                .frame(width: 34, height: 34)
                                .background(.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Work out Replay genres")
                                    .font(.system(size: 14, weight: .semibold))
                                Text(model.replay.genreStatus.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { model.replay.genresEnabled },
                                set: { model.replay.genresEnabled = $0 }
                            ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .padding(16)

                        Divider().padding(.leading, 64)

                        BackupActionRow(
                            icon: "square.and.arrow.up.fill",
                            color: .purple,
                            title: "Export Backup",
                            subtitle: "Settings, search history and every month of Replay",
                            action: model.exportBackup
                        )
                        .disabled(model.backupBusy)
                        Divider().padding(.leading, 64)
                        BackupActionRow(
                            icon: "square.and.arrow.down.fill",
                            color: .pink,
                            title: "Import Backup",
                            subtitle: "Validate and preview before replacing local data",
                            action: model.chooseBackupForRestore
                        )
                        .disabled(model.backupBusy)
                    }
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if model.backupBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working with backup…")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    } else if let status = model.backupStatus {
                        HStack(spacing: 8) {
                            Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            Text(status.message)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.isError ? .red : .green)
                        .padding(.horizontal, 4)
                    }

                    Text("YouTube and scrobbling credentials, source-module URLs, downloads and imported audio never leave this Mac in a backup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 28)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $editingSource) {
            SourceModuleEditor(sources: sources)
        }
        .sheet(isPresented: $editingSpotifyCanvas) {
            SpotifyCanvasSetupView(settings: model.spotifyCanvasSettings)
        }
        .sheet(item: $connectingScrobbler) { service in
            switch service {
            case .lastFM:
                LastFMConnectionView(scrobbling: scrobbling)
            case .listenBrainz:
                ListenBrainzConnectionView(scrobbling: scrobbling)
            }
        }
        .onAppear(perform: model.refreshAudioCacheSnapshot)
    }

    private var sourceStatusColor: Color {
        switch sources.health {
        case .connected: .green
        case .checking: .orange
        case .rejected, .unreachable: .red
        case .notConfigured: .secondary
        }
    }

    private static func speedLabel(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    private static let gibibyte = Double(1_024 * 1_024 * 1_024)

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

private struct SpotifyCanvasSetupView: View {
    @ObservedObject var settings: SpotifyCanvasSettings
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles.tv.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .background(.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Spotify Canvas")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Optional original vertical motion artwork")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(24)

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 18) {
                Text("Lilt needs the value of your Spotify web session cookie. It is saved only in this Mac's Keychain, never included in backups, and is sent only to spotify.com to mint the same short-lived token used by the web player.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Sign in at open.spotify.com in your browser.\n2. Open Developer Tools → Application → Cookies.\n3. Copy the value named sp_dc and paste it below.")
                        .font(.system(size: 13, weight: .medium))
                        .lineSpacing(4)
                    SecureField("sp_dc cookie value", text: $cookie)
                        .textFieldStyle(.roundedBorder)
                }

                if let error = settings.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }

                HStack {
                    if settings.isConfigured {
                        Button("Disconnect", role: .destructive) {
                            settings.remove()
                            cookie = ""
                        }
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(settings.isConfigured ? "Replace Session" : "Connect") {
                        if settings.save(cookie) { dismiss() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(width: 560)
        .background(BitChordBackground())
    }
}

private enum ScrobblingConnection: String, Identifiable {
    case lastFM
    case listenBrainz

    var id: String { rawValue }
}

private struct ScrobblingServiceRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let isConnected: Bool
    @Binding var isEnabled: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            if isConnected {
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                Button("Disconnect", action: onDisconnect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Connect", action: onConnect)
                    .buttonStyle(.borderedProminent)
                    .tint(color)
                    .controlSize(.small)
            }
        }
        .padding(16)
    }
}

private struct ScrobblingToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(16)
    }
}

private struct ScrobblingSliderRow: View {
    let title: String
    let value: String
    let subtitle: String
    @Binding var sliderValue: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.pink)
            }
            Slider(value: $sliderValue, in: range, step: step)
                .tint(.pink)
        }
    }
}

private struct LastFMConnectionView: View {
    @ObservedObject var scrobbling: ScrobblingManager
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = LastFMClient.defaultEndpoint
    @State private var apiKey = ""
    @State private var secret = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect Last.fm")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("Lilt exchanges your password once for a revocable session key. The password is never saved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(scrobbling.isConnecting)
            }

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("API endpoint") {
                    TextField("https://ws.audioscrobbler.com/2.0/", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 310)
                }
                LabeledContent("API key") {
                    SecureField("32-character API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 310)
                }
                LabeledContent("Shared secret") {
                    SecureField("Last.fm shared secret", text: $secret)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 310)
                }
                Divider()
                LabeledContent("Username") {
                    TextField("Last.fm username or email", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 310)
                }
                LabeledContent("Password") {
                    SecureField("Last.fm password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 310)
                        .onSubmit(connect)
                }
            }
            .disabled(scrobbling.isConnecting)

            if let error = scrobbling.connectionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }

            HStack {
                Link("Create or view Last.fm API credentials", destination: URL(string: "https://www.last.fm/api/accounts")!)
                    .font(.caption)
                Spacer()
                if scrobbling.isConnecting {
                    ProgressView().controlSize(.small)
                }
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .keyboardShortcut(.defaultAction)
                    .disabled(scrobbling.isConnecting || [apiKey, secret, username, password].contains { $0.isEmpty })
            }
        }
        .padding(26)
        .frame(width: 590)
        .onAppear {
            endpoint = scrobbling.lastFMEndpoint
            scrobbling.clearConnectionError()
        }
    }

    private func connect() {
        guard !scrobbling.isConnecting else { return }
        Task {
            let connected = await scrobbling.connectLastFM(
                endpoint: endpoint,
                apiKey: apiKey,
                secret: secret,
                username: username,
                password: password
            )
            password = ""
            if connected { dismiss() }
        }
    }
}

private struct ListenBrainzConnectionView: View {
    @ObservedObject var scrobbling: ScrobblingManager
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect ListenBrainz")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("Paste your user token. Lilt verifies it before enabling scrobbling and stores it only in Keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(scrobbling.isConnecting)
            }

            SecureField("ListenBrainz user token", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
                .disabled(scrobbling.isConnecting)

            if let error = scrobbling.connectionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }

            HStack {
                Link("Open ListenBrainz token settings", destination: URL(string: "https://listenbrainz.org/settings/")!)
                    .font(.caption)
                Spacer()
                if scrobbling.isConnecting {
                    ProgressView().controlSize(.small)
                }
                Button("Verify & Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .keyboardShortcut(.defaultAction)
                    .disabled(scrobbling.isConnecting || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(26)
        .frame(width: 540)
        .onAppear { scrobbling.clearConnectionError() }
    }

    private func connect() {
        guard !scrobbling.isConnecting else { return }
        Task {
            if await scrobbling.connectListenBrainz(token: token) {
                token = ""
                dismiss()
            }
        }
    }
}

private struct BackupActionRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct BackupRestoreSheet: View {
    @ObservedObject var model: AppModel
    let candidate: BackupCandidate
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "externaldrive.badge.timemachine")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.pink)
                    .frame(width: 58, height: 58)
                    .background(.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Restore Lilt Backup?")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(candidate.sourceURL.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(model.backupBusy)
            }

            HStack(spacing: 10) {
                BackupPreviewMetric(value: "\(candidate.preview.months)", label: "Replay months")
                BackupPreviewMetric(value: "\(candidate.preview.tracks)", label: "tracked songs")
                BackupPreviewMetric(
                    value: "\(candidate.preview.compatibleSettings)/\(candidate.preview.settings)",
                    label: "settings used"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Lilt \(candidate.preview.versionName)", systemImage: "app.badge.checkmark")
                Label(candidate.preview.dateText, systemImage: "calendar")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            Text("This replaces playback and download settings, search history and Replay on this Mac. Your YouTube sign-in, source module, downloaded music and imported files stay exactly where they are.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.orange.opacity(0.18), lineWidth: 1)
                }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .disabled(model.backupBusy)
                Spacer()
                if model.backupBusy {
                    ProgressView().controlSize(.small)
                }
                Button("Replace Settings & Replay", role: .destructive) {
                    model.restoreBackup(candidate)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.backupBusy)
            }
        }
        .padding(26)
        .frame(width: 590)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(model.backupBusy)
    }
}

private struct BackupPreviewMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct SourceModuleEditor: View {
    @ObservedObject var sources: SourceModuleManager
    @Environment(\.dismiss) private var dismiss
    @State private var url: String
    @State private var label: String
    @State private var enabled: Bool
    @State private var testing = false
    @State private var testResult: ModuleSourceHealth?

    init(sources: SourceModuleManager) {
        self.sources = sources
        _url = State(initialValue: sources.indexURLString)
        _label = State(initialValue: sources.label)
        _enabled = State(initialValue: sources.enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(sources.indexURLString.isEmpty ? "Add Module Source" : "Edit Module Source")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Compatible with the same module-index and JavaScript exports used by the Android app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("MODULE INDEX URL")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                TextField("https://example.com/modules/index.json", text: $url)
                    .textFieldStyle(.roundedBorder)
                Text("The index may contain Tidal, Qobuz, Apple Music or other modules. JavaScript receives only fetch/timer helpers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("NAME")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                TextField("Optional", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Use this source for High quality playback", isOn: $enabled)
                .toggleStyle(.switch)

            if let testResult {
                HStack(spacing: 8) {
                    Image(systemName: testResult.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(testResult.statusLine)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(testResult.isConnected ? .green : .orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack {
                if !sources.indexURLString.isEmpty {
                    Button("Remove Source", role: .destructive) {
                        sources.remove()
                        dismiss()
                    }
                }
                Spacer()
                Button(testing ? "Testing…" : "Test") {
                    testing = true
                    testResult = nil
                    Task {
                        testResult = await sources.probe(url: url)
                        testing = false
                    }
                }
                .disabled(testing || !validURL)
                Button("Save") {
                    sources.save(url: url, label: label, enabled: enabled)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(!validURL)
            }
        }
        .padding(26)
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var validURL: Bool {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") && parsed.host != nil
    }
}

private struct EqualizerSettingsCard: View {
    @ObservedObject var equalizer: EqualizerSettings
    let isAppliedToCurrentTrack: Bool

    private let labels = ["31", "62", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionTitle(
                title: "Equalizer",
                subtitle: "A native ten-band filter applied after decoding, including local and lossless audio."
            )

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.pink)
                        .frame(width: 34, height: 34)
                        .background(.pink.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("10-band equalizer")
                                .font(.system(size: 14, weight: .semibold))
                            if equalizer.isEnabled {
                                Text(isAppliedToCurrentTrack ? "ACTIVE" : "READY")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .tracking(0.6)
                                    .foregroundStyle(isAppliedToCurrentTrack ? .green : .pink)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(
                                        (isAppliedToCurrentTrack ? Color.green : Color.pink).opacity(0.13),
                                        in: Capsule()
                                    )
                            }
                        }
                        Text(isAppliedToCurrentTrack
                             ? "Processing the current stream in real time"
                             : "Choose a preset or shape each frequency band")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $equalizer.isEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .padding(16)

                Divider().padding(.leading, 64)

                HStack {
                    Menu {
                        ForEach(EqualizerPreset.allCases.filter { $0 != .custom }) { preset in
                            Button {
                                equalizer.selectPreset(preset)
                            } label: {
                                if equalizer.preset == preset {
                                    Label(preset.title, systemImage: "checkmark")
                                } else {
                                    Text(preset.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(equalizer.preset.title)
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Spacer()
                    Button("Reset") { equalizer.selectPreset(.flat) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 13)

                HStack(alignment: .bottom, spacing: 10) {
                    EqualizerBandControl(
                        label: "PRE",
                        value: equalizer.preampDB,
                        range: EqualizerSnapshot.preampRange,
                        color: .orange,
                        onChange: equalizer.setPreamp
                    )

                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 1, height: 126)
                        .padding(.horizontal, 1)

                    ForEach(EqualizerSnapshot.frequencies.indices, id: \.self) { index in
                        EqualizerBandControl(
                            label: labels[index],
                            value: equalizer.bandGainsDB[index],
                            range: EqualizerSnapshot.gainRange,
                            color: index < 3 ? .pink : (index < 7 ? .purple : .cyan),
                            onChange: { equalizer.setBandGain($0, at: index) }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 15)
                .padding(.top, 16)
                .padding(.bottom, 15)
                .opacity(equalizer.isEnabled ? 1 : 0.42)
                .disabled(!equalizer.isEnabled)
                .animation(.easeOut(duration: 0.18), value: equalizer.isEnabled)
            }
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct EqualizerBandControl: View {
    let label: String
    let value: Float
    let range: ClosedRange<Float>
    let color: Color
    let onChange: (Float) -> Void

    var body: some View {
        VStack(spacing: 7) {
            Text(dbText(value))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(value == 0 ? .secondary : color)
                .frame(width: 31)
            EqualizerVerticalSlider(value: value, range: range, color: color, onChange: onChange)
                .frame(width: 31, height: 108)
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 31)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label == "PRE" ? "Equalizer preamp" : "Equalizer \(label) hertz")
        .accessibilityValue(dbText(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 1, range.upperBound))
            case .decrement: onChange(max(value - 1, range.lowerBound))
            @unknown default: break
            }
        }
    }

    private func dbText(_ value: Float) -> String {
        value > 0 ? "+\(Int(value.rounded()))" : "\(Int(value.rounded()))"
    }
}

private struct EqualizerVerticalSlider: View {
    let value: Float
    let range: ClosedRange<Float>
    let color: Color
    let onChange: (Float) -> Void
    @State private var hovering = false

    private var fraction: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .frame(width: 5)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .bottom, endPoint: .top))
                    .frame(width: 5, height: max(3, height * fraction))
                Circle()
                    .fill(.white)
                    .frame(width: hovering ? 14 : 12, height: hovering ? 14 : 12)
                    .shadow(color: color.opacity(0.55), radius: 5)
                    .position(x: geometry.size.width / 2, y: height * (1 - fraction))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let draggedFraction = min(max(1 - gesture.location.y / max(height, 1), 0), 1)
                        let raw = range.lowerBound + Float(draggedFraction) * (range.upperBound - range.lowerBound)
                        onChange(raw.rounded())
                    }
            )
            .onHover { hovering = $0 }
        }
    }
}

private struct SettingsSectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct QualitySettingRow: View {
    let title: String
    let subtitle: String
    @Binding var selection: AudioQuality
    let isActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: selection.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isActive ? .purple : .secondary)
                .frame(width: 34, height: 34)
                .background((isActive ? Color.purple : Color.white).opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    if isActive {
                        Text("IN USE")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.purple.opacity(0.13), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(AudioQuality.allCases) { quality in
                    Button {
                        selection = quality
                    } label: {
                        if selection == quality {
                            Label("\(quality.title) — \(quality.detail)", systemImage: "checkmark")
                        } else {
                            Text("\(quality.title) — \(quality.detail)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(selection.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(selection.hourlyEstimate)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(16)
    }
}

struct MiniPlayer: View {
    @ObservedObject var player: PlaybackController
    let theme: ArtworkThemeColors
    let reduceDynamicBlur: Bool
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            PlayerProgressBar(
                progress: player.progress,
                duration: player.duration,
                isEnabled: !player.isLoading,
                onSeek: player.seek,
                playedColors: [theme.accentColor, theme.washColor]
            )
            .frame(maxWidth: .infinity)

            HStack {
                Text(formatTime(player.progress))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)

            ZStack {
                HStack(spacing: 12) {
                    Button(action: onExpand) {
                        HStack(spacing: 11) {
                            ArtworkView(
                                url: player.currentTrack?.artworkURL,
                                title: player.currentTrack?.title ?? "Lilt",
                                size: 42
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(player.currentTrack?.title ?? "Nothing playing")
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Text(player.currentTrack?.artist ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 250, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    PlayerVolumeControl(
                        volume: player.volume,
                        onSetVolume: player.setVolume,
                        onToggleMute: player.toggleMute,
                        accentColors: [theme.accentColor, theme.washColor],
                        foregroundColor: theme.onBackgroundColor
                    )
                    .frame(width: 190)
                }

                HStack(spacing: 16) {
                    Button(action: player.previous) { Image(systemName: "backward.fill") }
                    if player.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                            .frame(width: 32, height: 32)
                            .background(theme.onBackgroundColor, in: Circle())
                    } else {
                        Button(action: player.togglePlayback) {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .frame(width: 32, height: 32)
                                    .background(theme.onBackgroundColor, in: Circle())
                                    .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: player.next) { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .foregroundStyle(theme.onBackgroundColor)
        .background {
            ZStack {
                if reduceDynamicBlur {
                    Rectangle().fill(theme.elevatedColor)
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                }
                LinearGradient(
                    colors: reduceDynamicBlur
                        ? [theme.elevatedColor, theme.backgroundColor]
                        : [theme.elevatedColor.opacity(0.52), theme.backgroundColor.opacity(0.38)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
    }
}

private struct PlayerProgressBar: View {
    let progress: TimeInterval
    let duration: TimeInterval
    let isEnabled: Bool
    let onSeek: (TimeInterval) -> Void
    var playedColors: [Color] = [.purple, .pink]
    @State private var dragFraction: CGFloat?
    @State private var hovering = false

    private var playedFraction: CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(CGFloat(progress / duration), 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let fraction = dragFraction ?? playedFraction
            let width = max(geometry.size.width, 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.13))
                    .frame(height: 4)
                Capsule()
                    .fill(LinearGradient(colors: playedColors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * fraction, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: hovering || dragFraction != nil ? 11 : 8, height: hovering || dragFraction != nil ? 11 : 8)
                    .shadow(color: .black.opacity(0.32), radius: 3, y: 1)
                    .offset(x: max(0, min(width - (hovering ? 11 : 8), width * fraction - 4)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .opacity(isEnabled && duration > 0 ? 1 : 0.45)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled, duration > 0 else { return }
                        dragFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { value in
                        guard isEnabled, duration > 0 else { return }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        dragFraction = nil
                        onSeek(duration * TimeInterval(fraction))
                    }
            )
            .onHover { hovering = $0 }
        }
        .frame(height: 15)
    }
}

private struct PlayerVolumeControl: View {
    let volume: Float
    let onSetVolume: (Double) -> Void
    let onToggleMute: () -> Void
    let accentColors: [Color]
    let foregroundColor: Color
    @State private var dragFraction: CGFloat?
    @State private var hovering = false

    private var displayedFraction: CGFloat {
        dragFraction ?? min(max(CGFloat(volume), 0), 1)
    }

    private var speakerImage: String {
        switch displayedFraction {
        case ...0.001: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleMute) {
                Image(systemName: speakerImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(foregroundColor.opacity(0.82))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help(displayedFraction <= 0.001 ? "Unmute" : "Mute")

            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let fraction = displayedFraction
                let thumbSize: CGFloat = hovering || dragFraction != nil ? 11 : 8

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.13))
                        .frame(height: 4)
                    Capsule()
                        .fill(LinearGradient(colors: accentColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: width * fraction, height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: .black.opacity(0.32), radius: 3, y: 1)
                        .offset(x: max(0, min(width - thumbSize, width * fraction - thumbSize / 2)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max(value.location.x / width, 0), 1)
                            dragFraction = fraction
                            onSetVolume(Double(fraction))
                        }
                        .onEnded { value in
                            let fraction = min(max(value.location.x / width, 0), 1)
                            dragFraction = nil
                            onSetVolume(Double(fraction))
                        }
                )
                .onHover { hovering = $0 }
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onSetVolume(Double(volume) + 0.05)
                    case .decrement: onSetVolume(Double(volume) - 0.05)
                    @unknown default: break
                    }
                }
            }
            .frame(height: 20)

            Text("\(Int((displayedFraction * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(foregroundColor.opacity(0.72))
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: 24)
    }
}

struct NowPlayingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlaybackController
    @ObservedObject var artworkTheme: ArtworkThemeLoader
    @ObservedObject var canvas: CanvasController
    @Environment(\.dismiss) private var dismiss
    @State private var panel: NowPlayingPanel = .lyrics

    private var canvasAllowed: Bool {
        model.playbackSettings.animatedCanvas &&
            (!model.playbackSettings.networkIsMetered || model.playbackSettings.canvasOverMetered)
    }

    private var canvasRequestKey: String {
        "\(player.currentTrack?.id ?? "none")|\(player.currentTrack?.album ?? "")|\(canvasAllowed)"
    }

    var body: some View {
        let theme = artworkTheme.colors
        let fullBleedArtwork = model.playbackSettings.fullBleedArtwork
        let artworkWidth: CGFloat = fullBleedArtwork ? 420 : 280
        let artworkHeight: CGFloat = fullBleedArtwork ? 250 : 280
        let artworkCornerRadius: CGFloat = fullBleedArtwork ? 18 : 29
        ZStack {
            ArtworkThemeBackdrop(
                colors: theme,
                reduceAnimation: model.playbackSettings.reduceAnimation,
                reduceDynamicBlur: model.playbackSettings.reduceDynamicBlur
            )
                .ignoresSafeArea()
            HStack(spacing: 46) {
                VStack(spacing: 12) {
                    ZStack {
                        Text("NOW PLAYING")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(theme.secondaryTextColor.opacity(0.72))

                        HStack {
                            Button("Done") { dismiss() }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.secondaryTextColor)
                                .frame(minWidth: 64, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            Spacer()
                            PlaybackOptionsMenu(
                                model: model,
                                player: player,
                                settings: model.playbackSettings,
                                onNavigate: { dismiss() }
                            )
                        }
                    }
                    .frame(height: 44)
                    .contentShape(Rectangle())
                    .zIndex(20)
                    ZStack(alignment: .bottom) {
                        ArtworkView(
                            url: player.currentTrack?.artworkURL,
                            title: player.currentTrack?.title ?? "Lilt",
                            width: artworkWidth,
                            height: artworkHeight,
                            cornerRadius: artworkCornerRadius
                        )
                        if let artwork = canvas.artwork {
                            CanvasVideoView(artwork: artwork, onReady: canvas.markRendered)
                                .frame(width: artworkWidth, height: artworkHeight)
                                .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius, style: .continuous))
                                .opacity(canvas.rendered ? 1 : 0)
                                .animation(.easeInOut(duration: 0.45), value: canvas.rendered)
                                .accessibilityLabel("Animated cover art from \(artwork.source.title)")

                            if canvas.rendered {
                                Label(artwork.source.title, systemImage: "sparkles.tv.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(.black.opacity(0.52), in: Capsule())
                                    .padding(12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                    .transition(.opacity)
                            }
                        }
                        if model.playbackSettings.showNerdStats,
                           let stats = player.streamInfo?.technicalDescription {
                            Text(stats)
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.48), in: Capsule())
                                .padding(12)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .frame(width: artworkWidth, height: artworkHeight)
                    .shadow(color: theme.accentColor.opacity(0.32), radius: 44)
                    .animation(.easeInOut(duration: 0.34), value: fullBleedArtwork)
                    .animation(.easeOut(duration: 0.22), value: model.playbackSettings.showNerdStats)
                    VStack(spacing: 5) {
                        Text(player.currentTrack?.title ?? "Nothing playing")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .foregroundStyle(theme.onBackgroundColor)
                        Text(player.currentTrack?.artist ?? "")
                            .foregroundStyle(theme.secondaryTextColor)
                    }
                    if let track = player.currentTrack, track.videoID != nil, !track.isLocal {
                        HStack(spacing: 18) {
                            Button { model.toggleLike(track) } label: {
                                Image(systemName: model.likeStatus(for: track) == .like ? "heart.fill" : "heart")
                                    .foregroundStyle(model.likeStatus(for: track) == .like ? theme.accentColor : theme.secondaryTextColor)
                            }
                            .disabled(track.videoID.map(model.ratingInFlight.contains) == true)
                            .help(model.likeStatus(for: track) == .like ? "Remove like" : "Like")
                            Button { model.presentPlaylistPicker(for: track) } label: {
                                Image(systemName: "text.badge.plus")
                                    .foregroundStyle(theme.secondaryTextColor)
                            }
                            .help("Add to playlist")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 17, weight: .semibold))
                    }
                    if player.playbackRate != 1 || player.sleepTimerEnd != nil || player.stopAfterCurrent || player.skipSilenceEnabled || player.spatialAudioActive || player.equalizerActive || player.automixEnabled || (model.playbackSettings.showNerdStats && player.streamInfo != nil) {
                        HStack(spacing: 8) {
                            if model.playbackSettings.showNerdStats, let info = player.streamInfo {
                                Label(info.shortDescription, systemImage: "waveform")
                            }
                            if player.playbackRate != 1 {
                                Label("\(player.playbackRate.formatted(.number.precision(.fractionLength(0...2))))×", systemImage: "speedometer")
                            }
                            if player.skipSilenceEnabled {
                                Label("Skip silence", systemImage: "forward.end.alt.fill")
                            }
                            if player.spatialAudioActive {
                                Label("Spatial", systemImage: "hifispeaker.2.fill")
                            }
                            if player.equalizerActive {
                                Label(model.equalizer.preset.title, systemImage: "slider.vertical.3")
                            }
                            if player.automixEnabled {
                                Label(player.automixStatus.title, systemImage: "waveform.path.ecg.rectangle.fill")
                            }
                            if let end = player.sleepTimerEnd {
                                Label(end.formatted(date: .omitted, time: .shortened), systemImage: "moon.zzz.fill")
                            } else if player.stopAfterCurrent {
                                Label("After this track", systemImage: "moon.zzz.fill")
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.secondaryTextColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.elevatedColor.opacity(0.64), in: Capsule())
                    }
                    PlayerProgressBar(
                        progress: player.progress,
                        duration: player.duration,
                        isEnabled: !player.isLoading,
                        onSeek: player.seek,
                        playedColors: [theme.accentColor, theme.washColor]
                    )
                    HStack {
                        Text(formatTime(player.progress))
                        Spacer()
                        Text(formatTime(player.duration))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondaryTextColor.opacity(0.72))
                    if !model.playbackSettings.hideVolumeBar {
                        PlayerVolumeControl(
                            volume: player.volume,
                            onSetVolume: player.setVolume,
                            onToggleMute: player.toggleMute,
                            accentColors: [theme.accentColor, theme.washColor],
                            foregroundColor: theme.secondaryTextColor
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    HStack(spacing: 28) {
                        Button(action: player.previous) { Image(systemName: "backward.fill") }
                        if player.isLoading {
                            ProgressView()
                                .controlSize(.regular)
                                .tint(.black)
                                .frame(width: 58, height: 58)
                                .background(theme.onBackgroundColor, in: Circle())
                        } else {
                            Button(action: player.togglePlayback) {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 19, weight: .bold))
                                    .frame(width: 58, height: 58)
                                    .background(theme.onBackgroundColor, in: Circle())
                                    .foregroundStyle(.black)
                            }
                            .buttonStyle(.plain)
                        }
                        Button(action: player.next) { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    HStack(spacing: 10) {
                        PlaybackModeButton(
                            title: "Shuffle",
                            systemImage: "shuffle",
                            isActive: player.shuffleEnabled,
                            accent: theme.accentColor,
                            action: player.toggleShuffle
                        )
                        PlaybackModeButton(
                            title: player.repeatMode.title,
                            systemImage: player.repeatMode.systemImage,
                            isActive: player.repeatMode != .off,
                            accent: theme.accentColor,
                            action: player.cycleRepeatMode
                        )
                        PlaybackModeButton(
                            title: "AutoPlay",
                            systemImage: "infinity",
                            isActive: model.playbackSettings.autoplay,
                            accent: theme.accentColor,
                            action: { model.playbackSettings.autoplay.toggle() }
                        )
                    }
                }
                .frame(width: 420)

                VStack(alignment: .leading, spacing: 16) {
                    Picker("Now Playing Panel", selection: $panel) {
                        ForEach(NowPlayingPanel.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .tint(theme.accentColor)

                    switch panel {
                    case .lyrics:
                        NowPlayingLyricsPanel(player: player)
                    case .queue:
                        NowPlayingQueuePanel(player: player)
                    }
                }
                .frame(width: 330)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
        }
        .foregroundStyle(theme.onBackgroundColor)
        .tint(theme.accentColor)
        .frame(minWidth: 900, minHeight: 680)
        .preferredColorScheme(.dark)
        .task { player.loadLyrics() }
        .task(id: canvasRequestKey) {
            canvas.load(track: player.currentTrack, allowed: canvasAllowed)
        }
        .sheet(item: $model.playlistTrack) { track in
            PlaylistPickerView(model: model, track: track)
        }
    }

}

private struct PlaybackModeButton: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? accent : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isActive ? accent.opacity(0.16) : Color.white.opacity(0.055),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(isActive ? accent.opacity(0.35) : Color.white.opacity(0.07), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct PlaybackOptionsMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlaybackController
    @ObservedObject var settings: PlaybackSettings
    let onNavigate: () -> Void
    private let rates = PlaybackSettings.supportedRates

    var body: some View {
        Menu {
            Menu("Playback Speed") {
                ForEach(rates, id: \.self) { rate in
                    Button {
                        settings.playbackSpeed = rate
                    } label: {
                        if player.playbackRate == rate {
                            Label("\(rate.formatted(.number.precision(.fractionLength(0...2))))×", systemImage: "checkmark")
                        } else {
                            Text("\(rate.formatted(.number.precision(.fractionLength(0...2))))×")
                        }
                    }
                }
            }
            Menu("Sleep Timer") {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) minutes") {
                        player.scheduleSleepTimer(after: TimeInterval(minutes * 60))
                    }
                }
                Button("Stop After This Track") { player.setStopAfterCurrent() }
                if player.sleepTimerEnd != nil || player.stopAfterCurrent {
                    Divider()
                    Button("Cancel Timer", role: .destructive) { player.cancelSleepTimer() }
                }
            }
            Divider()
            Button {
                player.toggleShuffle()
            } label: {
                Label(
                    player.shuffleEnabled ? "Shuffle On" : "Shuffle Off",
                    systemImage: player.shuffleEnabled ? "checkmark" : "shuffle"
                )
            }
            Menu("Repeat") {
                ForEach(PlaybackRepeatMode.allCases, id: \.self) { mode in
                    Button {
                        player.setRepeatMode(mode)
                    } label: {
                        if player.repeatMode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Label(mode.title, systemImage: mode.systemImage)
                        }
                    }
                }
            }
            Toggle("AutoPlay", isOn: $settings.autoplay)
            Toggle("Skip Silence", isOn: $settings.skipSilence)
            Menu("Streaming Quality") {
                ForEach(AudioQuality.allCases) { quality in
                    Button {
                        if settings.networkIsMetered {
                            settings.meteredQuality = quality
                        } else {
                            settings.unmeteredQuality = quality
                        }
                    } label: {
                        if settings.effectiveQuality == quality {
                            Label(quality.title, systemImage: "checkmark")
                        } else {
                            Text(quality.title)
                        }
                    }
                }
            }
            if let track = player.currentTrack, track.videoID != nil {
                Divider()
                TrackNavigationMenuActions(
                    model: model,
                    track: track,
                    beforeOpen: onNavigate
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 17))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onAppear {
            if let track = player.currentTrack {
                model.resolveTrackLinksIfNeeded(track)
            }
        }
    }
}

private enum NowPlayingPanel: String, CaseIterable, Identifiable {
    case lyrics
    case queue

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct NowPlayingLyricsPanel: View {
    @ObservedObject var player: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Lyrics")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                if let lyrics = player.lyrics {
                    HStack(spacing: 5) {
                        Image(systemName: lyrics.isWordSynced ? "textformat.abc.dottedunderline" : "text.alignleft")
                        Text(lyrics.source)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(lyrics.isWordSynced ? .pink : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.06), in: Capsule())
                }
                if player.lyricsLoading { ProgressView().controlSize(.small) }
                Button(action: player.reloadLyrics) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reload lyrics")
            }
            if let lyrics = player.lyrics {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(lyrics.lines) { line in
                                SyncedLyricLine(
                                    line: line,
                                    position: player.progress,
                                    isCurrent: isCurrent(line)
                                )
                                    .id(line.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: player.progress) { _ in
                        if let current = lyrics.lines.last(where: { $0.start <= player.progress }) {
                            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(current.id, anchor: .center) }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if player.lyricsLoading {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking enabled lyric sources…")
                            .font(.callout.weight(.semibold))
                    } else {
                        Image(systemName: "text.quote")
                            .font(.system(size: 24))
                            .foregroundStyle(.purple)
                        Text("No synced lyrics found")
                            .font(.headline)
                        Text("Lilt checked every enabled provider. You can change their order or disable individual services in Settings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 28)
            }
            Spacer()
        }
    }

    private func isCurrent(_ line: LyricLine) -> Bool {
        guard let lines = player.lyrics?.lines,
              let active = lines.last(where: { $0.start <= player.progress }) else { return false }
        return active.id == line.id
    }
}

private struct SyncedLyricLine: View {
    let line: LyricLine
    let position: TimeInterval
    let isCurrent: Bool

    var body: some View {
        if line.isGap {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(isCurrent ? Color.pink : Color.white.opacity(0.18))
                        .frame(width: 4, height: isCurrent ? CGFloat(8 + index * 4) : 5)
                }
            }
            .frame(height: 24)
            .animation(.easeInOut(duration: 0.35), value: isCurrent)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                highlightedText(line)
                    .font(.system(size: 17, weight: isCurrent ? .bold : .medium, design: .rounded))
                if let background = line.background {
                    highlightedText(background)
                        .font(.system(size: 13, weight: isCurrent ? .semibold : .medium, design: .rounded))
                        .opacity(0.74)
                }
            }
            .animation(.linear(duration: 0.12), value: position)
        }
    }

    private func highlightedText(_ value: LyricLine) -> Text {
        highlightedText(
            text: value.text,
            isWordSynced: value.isWordSynced,
            revealedCharacters: value.revealedCharacterCount(at: position)
        )
    }

    private func highlightedText(_ value: LyricBackground) -> Text {
        highlightedText(
            text: value.text,
            isWordSynced: value.isWordSynced,
            revealedCharacters: value.revealedCharacterCount(at: position)
        )
    }

    private func highlightedText(
        text: String,
        isWordSynced: Bool,
        revealedCharacters: Double
    ) -> Text {
        guard isCurrent else { return Text(text).foregroundColor(.white.opacity(0.30)) }
        guard isWordSynced else { return Text(text).foregroundColor(.white) }
        let revealed = max(0, min(text.count, Int(revealedCharacters.rounded(.down))))
        let prefix = String(text.prefix(revealed))
        let suffix = String(text.dropFirst(revealed))
        return Text(prefix).foregroundColor(.white)
            + Text(suffix).foregroundColor(.white.opacity(0.28))
    }
}

private struct NowPlayingQueuePanel: View {
    @ObservedObject var player: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Queue")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    player.clearUpcomingQueue()
                } label: {
                    Label("Clear Upcoming", systemImage: "xmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(player.hasUpcomingTracks ? .secondary : .tertiary)
                .disabled(!player.hasUpcomingTracks)
                .help("Clear upcoming tracks")
                Text("\(player.queue.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if player.queue.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.line.last.and.arrowtriangle.forward")
                        .font(.system(size: 28))
                        .foregroundStyle(.purple)
                    Text("The queue is empty")
                        .font(.headline)
                    Text("Use Play Next or Add to Queue from any song menu.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                            if index == player.autoplaySectionStart {
                                AutoplayQueueHeader(
                                    isLoading: player.autoplayLoading,
                                    isPaused: player.repeatMode == .all
                                )
                            }
                            QueueTrackRow(player: player, track: track, index: index)
                        }
                        if player.autoplayEnabled && player.autoplaySectionStart == player.queue.count {
                            AutoplayQueueHeader(
                                isLoading: player.autoplayLoading,
                                isPaused: player.repeatMode == .all
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct AutoplayQueueHeader: View {
    let isLoading: Bool
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "infinity")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.purple)
            Text("AUTOPLAY")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.15)
            Spacer()
            if isPaused {
                Text("Paused while repeating")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if isLoading {
                ProgressView()
                    .controlSize(.mini)
                Text("Finding more music")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

private struct QueueTrackRow: View {
    @ObservedObject var player: PlaybackController
    let track: Track
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            Button { player.playFromQueue(at: index) } label: {
                HStack(spacing: 10) {
                    ArtworkView(url: track.artworkURL, title: track.title, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)
            if index == player.queueIndex {
                Image(systemName: player.isLoading ? "hourglass" : "speaker.wave.2.fill")
                    .foregroundStyle(.purple)
                    .frame(width: 18)
            }
            Button { player.moveQueueItem(from: index, to: index - 1) } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(!player.canMoveQueueItem(from: index, to: index - 1))
            Button { player.moveQueueItem(from: index, to: index + 1) } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(!player.canMoveQueueItem(from: index, to: index + 1))
            Button { player.removeFromQueue(at: index) } label: {
                Image(systemName: "xmark")
            }
            .disabled(index == player.queueIndex)
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(index == player.queueIndex ? Color.purple.opacity(0.13) : Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ArtworkView: View {
    let url: String?
    let title: String
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    init(url: String?, title: String, size: CGFloat) {
        self.init(url: url, title: title, width: size, height: size, cornerRadius: max(10, size * 0.09))
    }

    init(url: String?, title: String, width: CGFloat, height: CGFloat, cornerRadius: CGFloat) {
        self.url = url
        self.title = title
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            placeholder
            if let url, let imageURL = URL(string: url) {
                if imageURL.isFileURL {
                    LocalArtworkImage(url: imageURL)
                } else {
                    AsyncImage(url: imageURL, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        default: Color.clear
                        }
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        let colors = palette(for: title)
        return ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "waveform")
                .font(.system(size: min(width, height) * 0.22, weight: .light))
                .foregroundStyle(.white.opacity(0.78))
        }
    }

    private func palette(for value: String) -> [Color] {
        let seed = value.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        let palettes: [[Color]] = [
            [.purple, .indigo], [.pink, .orange], [.blue, .cyan], [.teal, .green], [.red, .purple]
        ]
        return palettes[abs(seed) % palettes.count]
    }
}

private struct LocalArtworkImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.clear
            }
        }
        .task(id: url.path) {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      data.count <= LocalMediaIndexer.maximumArtworkBytes else { return nil }
                return data
            }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}

private struct BitChordBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.055, green: 0.055, blue: 0.075), Color(red: 0.025, green: 0.025, blue: 0.04)]
                : [Color(red: 0.985, green: 0.98, blue: 0.995), Color(red: 0.935, green: 0.945, blue: 0.975)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
            .ignoresSafeArea()
    }
}

private struct InlineNotice: View {
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle").foregroundStyle(.purple)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(actionTitle, action: action).buttonStyle(.bordered)
        }
        .padding(13)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension AppThemeMode {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private func formatTime(_ time: TimeInterval) -> String {
    guard time.isFinite, time >= 0 else { return "0:00" }
    let total = Int(time.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

private extension BrowseItem.Kind {
    var title: String {
        switch self {
        case .album: "Album"
        case .artist: "Artist"
        case .playlist: "Playlist"
        case .other: "Collection"
        }
    }
}

struct YouTubeLoginView: View {
    let onAuthenticated: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to YouTube Music")
                        .font(.headline)
                    Text("Google handles your credentials in this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()
            YouTubeLoginWebView(onAuthenticated: onAuthenticated)
        }
        .frame(minWidth: 780, minHeight: 620)
    }
}

private struct YouTubeLoginWebView: NSViewRepresentable {
    let onAuthenticated: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticated: onAuthenticated)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&continue=https%3A%2F%2Fmusic.youtube.com%2F")!))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let chromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
        private let onAuthenticated: (String) -> Void
        private var captured = false

        init(onAuthenticated: @escaping (String) -> Void) {
            self.onAuthenticated = onAuthenticated
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame ?? true else {
                decisionHandler(.allow)
                return
            }

            if isYouTubeNavigation(navigationAction.request.url) {
                // Google accepts the default WebKit/Safari identity for sign-in,
                // while YouTube Music requires a Chromium identity for its app shell.
                if webView.customUserAgent != chromeUserAgent,
                   let url = navigationAction.request.url {
                    webView.customUserAgent = chromeUserAgent
                    decisionHandler(.cancel)
                    DispatchQueue.main.async {
                        webView.load(URLRequest(url: url))
                    }
                    return
                }
            } else {
                webView.customUserAgent = nil
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            guard isYouTubeNavigation(navigationResponse.response.url) else {
                decisionHandler(.allow)
                return
            }

            captureCookiesIfAvailable(in: webView, url: navigationResponse.response.url) { authenticated in
                decisionHandler(authenticated ? .cancel : .allow)
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            captureCookiesIfAvailable(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            captureCookiesIfAvailable(in: webView)
        }

        private func isYouTubeNavigation(_ url: URL?) -> Bool {
            guard let host = url?.host?.lowercased() else { return false }
            return host == "youtube.com" || host.hasSuffix(".youtube.com")
        }

        private func captureCookiesIfAvailable(
            in webView: WKWebView,
            url: URL? = nil,
            completion: ((Bool) -> Void)? = nil
        ) {
            guard !captured, isYouTubeNavigation(url ?? webView.url) else {
                completion?(false)
                return
            }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                // Match Android's CookieManager.getCookie(MUSIC_ORIGIN): only
                // cookies the browser would actually send to music.youtube.com.
                // Joining the whole Google + YouTube cookie store mixed
                // duplicate account cookies from different domains; Google
                // then served a signed-out shell while the UI claimed success.
                let host = "music.youtube.com"
                let now = Date()
                let applicable = cookies.filter { cookie in
                    let domain = cookie.domain
                        .lowercased()
                        .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    let domainMatches = host == domain || host.hasSuffix(".\(domain)")
                    let pathMatches = "/".hasPrefix(cookie.path)
                    let unexpired = cookie.expiresDate.map { $0 > now } ?? true
                    return domainMatches && pathMatches && unexpired
                }
                .sorted {
                    let lhsDomain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    let rhsDomain = $1.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if lhsDomain.count != rhsDomain.count { return lhsDomain.count > rhsDomain.count }
                    return $0.path.count > $1.path.count
                }

                var seenNames = Set<String>()
                let authCookies = applicable.filter { seenNames.insert($0.name).inserted }
                let header = authCookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                let authenticated = AuthStore.hasAPISID(header)

                DispatchQueue.main.async {
                    guard let self else {
                        completion?(false)
                        return
                    }
                    if authenticated && !self.captured {
                        self.captured = true
                        self.onAuthenticated(header)
                    }
                    completion?(authenticated)
                }
            }
        }
    }
}
