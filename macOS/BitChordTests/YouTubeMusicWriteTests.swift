import Foundation
import XCTest

@MainActor
final class YouTubeMusicWriteTests: XCTestCase {
    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
    }

    func testLikeUsesSignedEndpointAndVideoTarget() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                capturedRequest = request
                capturedBody = Self.bodyData(from: request)
                return Self.response(for: request, json: [:])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        try await api.rate(videoID: "video-123", status: .like)

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/youtubei/v1/like/like")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "0")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        let target = try XCTUnwrap(payload["target"] as? [String: Any])
        XCTAssertEqual(target["videoId"] as? String, "video-123")
        XCTAssertNotNil(payload["context"])
    }

    func testPlaylistAddSendsRawPlaylistIDAndReturnsSetVideoID() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                capturedRequest = request
                capturedBody = Self.bodyData(from: request)
                return Self.response(for: request, json: [
                    "status": "STATUS_SUCCEEDED",
                    "playlistEditResults": [[
                        "playlistEditVideoAddedResultData": [
                            "videoId": "video-1",
                            "setVideoId": "set-1"
                        ]
                    ]]
                ])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        let added = try await api.addToPlaylist(playlistID: "VLPL-owned", videoIDs: ["video-1"])

        XCTAssertEqual(added, ["video-1": "set-1"])
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/youtubei/v1/browse/edit_playlist")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(payload["playlistId"] as? String, "PL-owned")
        let actions = try XCTUnwrap(payload["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.first?["action"] as? String, "ACTION_ADD_VIDEO")
        XCTAssertEqual(actions.first?["addedVideoId"] as? String, "video-1")
    }

    func testHTTP200ErrorBodyIsReportedAsFailure() async throws {
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                return Self.response(for: request, json: ["error": ["message": "write refused"]])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        do {
            try await api.rate(videoID: "video-123", status: .dislike)
            XCTFail("Expected a refused account write")
        } catch {
            XCTAssertEqual(error.localizedDescription, "write refused")
        }
    }

    func testEditablePlaylistHeaderEnablesOwnedPlaylistActions() async throws {
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                return Self.response(for: request, json: [
                    "header": [
                        "musicEditablePlaylistDetailHeaderRenderer": ["title": "Owned playlist"]
                    ],
                    "contents": []
                ])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        _ = try await api.tracks(for: "VLOWNED123")

        XCTAssertTrue(api.isEditablePlaylist("VLOWNED123"))
        XCTAssertFalse(api.isEditablePlaylist("VLSAVED456"))
    }

    func testSharedBrowsePageUsesHeaderAndRowsFromOneRequest() async throws {
        var browseRequests = 0
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                browseRequests += 1
                return Self.response(for: request, json: [
                    "header": [
                        "musicDetailHeaderRenderer": [
                            "title": ["runs": [["text": "Shared Album"]]],
                            "subtitle": ["runs": [["text": "Album • Test Artist"]]],
                            "thumbnail": ["thumbnails": [["url": "https://img.example/album.jpg"]]]
                        ]
                    ],
                    "contents": [
                        Self.historyRow(videoID: "abcdefghijk", title: "First Song", artist: "Test Artist")
                    ]
                ])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        let page = try await api.page(for: "MPREb_shared")

        XCTAssertEqual(browseRequests, 1)
        XCTAssertEqual(page.item.id, "MPREb_shared")
        XCTAssertEqual(page.item.title, "Shared Album")
        XCTAssertEqual(page.item.subtitle, "Album • Test Artist")
        XCTAssertEqual(page.item.artworkURL, "https://img.example/album.jpg")
        XCTAssertEqual(page.item.kind, .album)
        XCTAssertEqual(page.tracks.map(\.videoID), ["abcdefghijk"])
    }

    func testRemoveFromPlaylistUsesSetVideoIdentity() async throws {
        var capturedBody: Data?
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                capturedBody = Self.bodyData(from: request)
                return Self.response(for: request, json: ["status": "STATUS_SUCCEEDED"])
            }
            return Self.sessionBootstrapResponse(for: request)
        }
        let track = Track(
            videoID: "video-1",
            title: "Song",
            artist: "Artist",
            album: nil,
            artworkURL: nil,
            duration: nil,
            localPath: nil,
            sourceURL: nil,
            setVideoID: "set-1"
        )

        try await api.removeFromPlaylist(playlistID: "VLOWNED123", track: track)

        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        let actions = try XCTUnwrap(payload["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.first?["action"] as? String, "ACTION_REMOVE_VIDEO")
        XCTAssertEqual(actions.first?["setVideoId"] as? String, "set-1")
        XCTAssertEqual(actions.first?["removedVideoId"] as? String, "video-1")
    }

    func testCreatePlaylistSendsPrivacyAndSeedTrackThenReturnsID() async throws {
        var capturedBody: Data?
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                capturedBody = Self.bodyData(from: request)
                return Self.response(for: request, json: ["playlistId": "PL-created"])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        let playlistID = try await api.createPlaylist(
            title: "Temporary",
            privacy: .unlisted,
            videoIDs: ["abcdefghijk"]
        )

        XCTAssertEqual(playlistID, "PL-created")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(payload["title"] as? String, "Temporary")
        XCTAssertEqual(payload["privacyStatus"] as? String, "UNLISTED")
        XCTAssertEqual(payload["videoIds"] as? [String], ["abcdefghijk"])
    }

    func testRenamePlaylistUsesSetNameActionAndRawPlaylistID() async throws {
        var capturedBody: Data?
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                capturedBody = Self.bodyData(from: request)
                return Self.response(for: request, json: ["status": "STATUS_SUCCEEDED"])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        try await api.renamePlaylist(playlistID: "VLPL-owned", title: "Renamed")

        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(payload["playlistId"] as? String, "PL-owned")
        let actions = try XCTUnwrap(payload["actions"] as? [[String: Any]])
        XCTAssertEqual(actions.first?["action"] as? String, "ACTION_SET_PLAYLIST_NAME")
        XCTAssertEqual(actions.first?["playlistName"] as? String, "Renamed")
    }

    func testDeletePlaylistUsesDeleteEndpointAndRawPlaylistID() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                capturedRequest = request
                capturedBody = Self.bodyData(from: request)
                return Self.response(for: request, json: [:])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        try await api.deletePlaylist(playlistID: "VLPL-owned")

        XCTAssertEqual(capturedRequest?.url?.path, "/youtubei/v1/playlist/delete")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(payload["playlistId"] as? String, "PL-owned")
    }

    func testHistoryReadsNewestTracksAndDeduplicatesRepeatedPlays() async throws {
        let api = makeAPI { request in
            if request.httpMethod == "POST" {
                return Self.response(for: request, json: [
                    "contents": [
                        Self.historyRow(videoID: "abcdefghijk", title: "Newest", artist: "Artist A"),
                        Self.historyRow(videoID: "lmnopqrstuv", title: "Earlier", artist: "Artist B"),
                        Self.historyRow(videoID: "abcdefghijk", title: "Newest", artist: "Artist A")
                    ]
                ])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        let tracks = try await api.history()

        XCTAssertEqual(tracks.map(\.videoID), ["abcdefghijk", "lmnopqrstuv"])
        XCTAssertEqual(tracks.map(\.title), ["Newest", "Earlier"])
    }

    func testAutoplayUsesRadioMixAndParsesWatchQueueRows() async throws {
        var capturedBody: Data?
        let api = makeAPI { request in
            if request.httpMethod == "POST", request.url?.path == "/youtubei/v1/next" {
                capturedBody = Self.bodyData(from: request)
                return Self.response(for: request, json: [
                    "contents": [
                        ["playlistPanelVideoRenderer": [
                            "videoId": "seed-video",
                            "title": ["runs": [["text": "Seed Song"]]],
                            "longBylineText": ["runs": [
                                Self.creditRun(
                                    text: "Seed Artist",
                                    browseID: "UCseed",
                                    pageType: "MUSIC_PAGE_TYPE_ARTIST"
                                ),
                                ["text": " • "],
                                Self.creditRun(
                                    text: "Seed Album",
                                    browseID: "MPREseed",
                                    pageType: "MUSIC_PAGE_TYPE_ALBUM"
                                )
                            ]],
                            "lengthText": ["runs": [["text": "3:21"]]],
                            "thumbnail": ["thumbnails": [["url": "https://example.com/seed.jpg", "width": 120]]]
                        ]],
                        ["playlistPanelVideoRenderer": [
                            "videoId": "related-video",
                            "title": ["runs": [["text": "Related Song"]]],
                            "longBylineText": ["runs": [["text": "Related Artist"]]],
                            "lengthText": ["simpleText": "4:05"]
                        ]],
                        ["playlistPanelVideoRenderer": [
                            "videoId": "related-video",
                            "title": ["runs": [["text": "Duplicate"]]]
                        ]]
                    ]
                ])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        let tracks = try await api.autoplayTracks(for: "seed-video")

        XCTAssertEqual(tracks.map(\.videoID), ["seed-video", "related-video"])
        XCTAssertEqual(tracks.map(\.artist), ["Seed Artist", "Related Artist"])
        XCTAssertEqual(tracks.map(\.duration), [201, 245])
        XCTAssertEqual(tracks.first?.artistBrowseID, "UCseed")
        XCTAssertEqual(tracks.first?.albumBrowseID, "MPREseed")
        XCTAssertEqual(tracks.first?.album, "Seed Album")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(payload["videoId"] as? String, "seed-video")
        XCTAssertEqual(payload["playlistId"] as? String, "RDAMVMseed-video")
        XCTAssertEqual(payload["isAudioOnly"] as? Bool, true)
    }

    func testTrackLinksUsesSeedWatchEntryWithoutStartingRadio() async throws {
        var capturedBody: Data?
        let api = makeAPI { request in
            if request.httpMethod == "POST", request.url?.path == "/youtubei/v1/next" {
                capturedBody = Self.bodyData(from: request)
                return Self.response(for: request, json: [
                    "contents": [
                        ["playlistPanelVideoRenderer": [
                            "videoId": "unrelated-video",
                            "title": ["runs": [["text": "Unrelated"]]],
                            "longBylineText": ["runs": [["text": "Another Artist"]]]
                        ]],
                        ["playlistPanelVideoRenderer": [
                            "videoId": "seed-video",
                            "title": ["runs": [["text": "Seed Song"]]],
                            "longBylineText": ["runs": [
                                Self.creditRun(
                                    text: "Seed Artist",
                                    browseID: "UCseed",
                                    pageType: "MUSIC_PAGE_TYPE_ARTIST"
                                ),
                                ["text": " • "],
                                Self.creditRun(
                                    text: "Seed Album",
                                    browseID: "MPREseed",
                                    pageType: "MUSIC_PAGE_TYPE_ALBUM"
                                )
                            ]]
                        ]]
                    ]
                ])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        let track = try await api.trackLinks(for: "seed-video")

        XCTAssertEqual(track.videoID, "seed-video")
        XCTAssertEqual(track.artist, "Seed Artist")
        XCTAssertEqual(track.artistBrowseID, "UCseed")
        XCTAssertEqual(track.album, "Seed Album")
        XCTAssertEqual(track.albumBrowseID, "MPREseed")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any])
        XCTAssertEqual(payload["videoId"] as? String, "seed-video")
        XCTAssertEqual(payload["isAudioOnly"] as? Bool, true)
        XCTAssertNil(payload["playlistId"])
    }

    func testSongSearchDropsWidescreenVideoRowsAndKeepsCatalogueTracks() async throws {
        let api = makeAPI { request in
            if request.httpMethod == "POST", request.url?.path == "/youtubei/v1/search" {
                return Self.response(for: request, json: [
                    "contents": [
                        Self.searchTrackRow(
                            videoID: "video-upload",
                            title: "Song (Official Video)",
                            artist: "Artist",
                            duration: "3:21",
                            rowType: "Video",
                            width: 480,
                            height: 270
                        ),
                        Self.searchTrackRow(
                            videoID: "catalogue-audio",
                            title: "Song",
                            artist: "Artist",
                            duration: "3:20",
                            rowType: "Song",
                            width: 226,
                            height: 226
                        )
                    ]
                ])
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        let results = try await api.search(query: "Song Artist", filter: .songs)
        let tracks = results.compactMap { result -> Track? in
            guard case .track(let track) = result else { return nil }
            return track
        }

        XCTAssertEqual(tracks.map(\.videoID), ["catalogue-audio"])
        XCTAssertEqual(tracks.first?.artist, "Artist")
        XCTAssertFalse(tracks.first?.isMusicVideo == true)
    }

    func testHomeTwoRowMusicVideoCardIsMarkedForCatalogueResolution() async throws {
        let api = makeAPI { request in
            guard request.httpMethod == "POST", request.url?.path == "/youtubei/v1/browse" else {
                return Self.sessionBootstrapResponse(for: request)
            }
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            guard payload["browseId"] as? String == "FEmusic_home" else {
                return Self.response(for: request, json: [:])
            }
            return Self.response(for: request, json: [
                "contents": [
                    "musicCarouselShelfRenderer": [
                        "header": [
                            "musicCarouselShelfBasicHeaderRenderer": [
                                "title": ["runs": [["text": "Music videos"]]]
                            ]
                        ],
                        "contents": [Self.homeVideoCard(
                            videoID: "video-upload",
                            title: "I WANNA BE YOUR SLAVE (Official Video)",
                            subtitle: "Måneskin • 160M views"
                        )]
                    ]
                ]
            ])
        }

        let shelves = try await api.home()
        let track = try XCTUnwrap(shelves.first(where: { $0.title == "Music videos" })?.items.first?.track)

        XCTAssertEqual(track.videoID, "video-upload")
        XCTAssertEqual(track.artist, "Måneskin")
        XCTAssertTrue(track.isMusicVideo)
    }

    func testExploreMergesFeedsInAndroidOrderAndKeepsArtistChartRows() async throws {
        let api = makeAPI { request in
            guard request.httpMethod == "POST", request.url?.path == "/youtubei/v1/browse" else {
                return Self.sessionBootstrapResponse(for: request)
            }
            let body = try XCTUnwrap(Self.bodyData(from: request))
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            switch payload["browseId"] as? String {
            case "FEmusic_explore":
                return Self.response(for: request, json: Self.browseSections([
                    Self.albumShelf(title: "New releases", browseID: "MPRE-new")
                ]))
            case "FEmusic_charts":
                return Self.response(for: request, json: Self.browseSections([
                    Self.albumShelf(title: "New releases", browseID: "MPRE-duplicate"),
                    Self.albumShelf(title: "New music videos", browseID: "VL-video-only"),
                    Self.chartShelf(),
                    Self.artistChartShelf(title: "Top artists", browseID: "UC-top")
                ]))
            default:
                return Self.response(for: request, json: [:])
            }
        }

        let shelves = await api.explore()

        XCTAssertEqual(shelves.map(\.title), ["New releases", "Daily charts", "Top artists"])
        let charts = try XCTUnwrap(shelves.first(where: { $0.title == "Daily charts" }))
        XCTAssertEqual(charts.items.map(\.title), ["Trending 20 United States"])
        let artist = try XCTUnwrap(shelves.last?.items.first?.browseItem)
        XCTAssertEqual(artist.id, "UC-top")
        XCTAssertEqual(artist.title, "Chart Artist")
        XCTAssertEqual(artist.kind, .artist)
    }

    func testMusicVideoResolutionChoosesOnlyStrictCatalogueMatch() async throws {
        var capturedQuery: String?
        let api = makeAPI { request in
            if request.httpMethod == "POST", request.url?.path == "/youtubei/v1/search" {
                let body = try XCTUnwrap(Self.bodyData(from: request))
                let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                capturedQuery = payload["query"] as? String
                return Self.response(for: request, json: [
                    "contents": [
                        Self.searchTrackRow(
                            videoID: "live-take",
                            title: "Song (Live)",
                            artist: "Artist",
                            duration: "3:21"
                        ),
                        Self.searchTrackRow(
                            videoID: "long-edit",
                            title: "Song",
                            artist: "Artist",
                            duration: "5:10"
                        ),
                        Self.searchTrackRow(
                            videoID: "catalogue-audio",
                            title: "Song",
                            artist: "Artist",
                            duration: "3:20"
                        )
                    ]
                ])
            }
            return Self.sessionBootstrapResponse(for: request)
        }
        var video = Track(
            videoID: "video-upload",
            title: "Song (Official Video)",
            artist: "Artist",
            album: nil,
            artworkURL: nil,
            duration: 201,
            localPath: nil,
            sourceURL: nil
        )
        video.isVideo = true

        let resolved = await api.resolvePlaybackTrack(for: video)

        XCTAssertEqual(capturedQuery?.lowercased(), "song artist")
        XCTAssertEqual(resolved.videoID, "catalogue-audio")
        XCTAssertEqual(resolved.title, "Song")
        XCTAssertFalse(resolved.isMusicVideo)
    }

    func testMusicVideoResolutionCanBeDisabledWithoutNetworkWork() async throws {
        var requestCount = 0
        let api = makeAPI { request in
            requestCount += 1
            return Self.sessionBootstrapResponse(for: request)
        }
        api.setConvertVideoToAudio(false)
        var video = Track(
            videoID: "video-upload",
            title: "Song (Official Video)",
            artist: "Artist",
            album: nil,
            artworkURL: nil,
            duration: 201,
            localPath: nil,
            sourceURL: nil
        )
        video.isVideo = true

        let resolved = await api.resolvePlaybackTrack(for: video)

        XCTAssertEqual(resolved, video)
        XCTAssertEqual(requestCount, 0)
    }

    func testPlaybackTrackingUsesCurrentPlayerTimestampAndSignedSession() async throws {
        var playerRequest: URLRequest?
        var playerBody: Data?
        let api = makeAPI { request in
            switch (request.httpMethod, request.url?.host, request.url?.path) {
            case ("GET", "www.youtube.com", "/watch"):
                return Self.response(for: request, data: Data(#"<script src="/s/player/test/player_ias.vflset/en_US/base.js"></script>"#.utf8))
            case ("GET", "www.youtube.com", "/s/player/test/player_ias.vflset/en_US/base.js"):
                return Self.response(for: request, data: Data("signatureTimestamp:20684".utf8))
            case ("POST", "music.youtube.com", "/youtubei/v1/player"):
                playerRequest = request
                playerBody = Self.bodyData(from: request)
                return Self.response(for: request, json: [
                    "playbackTracking": [
                        "videostatsPlaybackUrl": ["baseUrl": "https://s.youtube.com/api/stats/playback?docid=abcdefghijk"],
                        "videostatsWatchtimeUrl": ["baseUrl": "https://s.youtube.com/api/stats/watchtime?docid=abcdefghijk"],
                        "atrUrl": [
                            "baseUrl": "https://s.youtube.com/api/stats/atr?docid=abcdefghijk",
                            "elapsedMediaTimeSeconds": 7
                        ]
                    ]
                ])
            default:
                return Self.sessionBootstrapResponse(for: request)
            }
        }

        let trackingResponse = try await api.playbackTracking(for: "abcdefghijk")
        let tracking = try XCTUnwrap(trackingResponse)

        XCTAssertEqual(tracking.atrAfterSeconds, 7)
        XCTAssertEqual(tracking.watchtimeURL, "https://s.youtube.com/api/stats/watchtime?docid=abcdefghijk")
        let request = try XCTUnwrap(playerRequest)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(playerBody)) as? [String: Any])
        let playbackContext = try XCTUnwrap(payload["playbackContext"] as? [String: Any])
        let contentContext = try XCTUnwrap(playbackContext["contentPlaybackContext"] as? [String: Any])
        XCTAssertEqual(contentContext["signatureTimestamp"] as? Int, 20_684)
    }

    func testFinalWatchtimePingCarriesPlaybackNonceAndSignedHeaders() async throws {
        var statsRequest: URLRequest?
        let api = makeAPI { request in
            if request.url?.host == "s.youtube.com" {
                statsRequest = request
                return Self.response(for: request, data: Data())
            }
            return Self.sessionBootstrapResponse(for: request)
        }

        try await api.pingWatchtime(
            "https://s.youtube.com/api/stats/watchtime?docid=abcdefghijk",
            cpn: "ABCDEF1234567890",
            seconds: 42,
            final: true
        )

        let request = try XCTUnwrap(statsRequest)
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let values = Dictionary(grouping: query.queryItems ?? [], by: \.name)
            .mapValues { $0.last?.value }
        XCTAssertEqual(values["cpn"] ?? nil, "ABCDEF1234567890")
        XCTAssertEqual(values["st"] ?? nil, "0")
        XCTAssertEqual(values["et"] ?? nil, "42")
        XCTAssertEqual(values["cmt"] ?? nil, "42")
        XCTAssertEqual(values["state"] ?? nil, "paused")
        XCTAssertEqual(values["final"] ?? nil, "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://music.youtube.com")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
    }

    private func makeAPI(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> YouTubeMusicAPI {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = YouTubeMusicAPI(session: URLSession(configuration: configuration))
        api.setCookie("SAPISID=test-secret; __Secure-3PAPISID=test-secret")
        return api
    }

    private static func sessionBootstrapResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
        if request.url?.host == "music.youtube.com" {
            let html = #"{"LOGGED_IN":true,"INNERTUBE_CLIENT_VERSION":"1.test","SESSION_INDEX":"0","VISITOR_DATA":"CgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#
            return response(for: request, data: Data(html.utf8))
        }
        return response(for: request, data: Data("CgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".utf8))
    }

    private static func historyRow(videoID: String, title: String, artist: String) -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": videoID],
                "flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": title]]]
                    ]],
                    ["musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": artist]]]
                    ]]
                ]
            ]
        ]
    }

    private static func browseSections(_ sections: [[String: Any]]) -> [String: Any] {
        [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": ["contents": sections]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
    }

    private static func albumShelf(title: String, browseID: String) -> [String: Any] {
        [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": title]]]
                    ]
                ],
                "contents": [[
                    "musicTwoRowItemRenderer": [
                        "title": ["runs": [["text": "Fixture Album"]]],
                        "subtitle": ["runs": [["text": "Album • Fixture Artist"]]],
                        "thumbnailRenderer": [
                            "musicThumbnailRenderer": [
                                "thumbnail": ["thumbnails": [["url": "https://img.example/album.jpg"]]]
                            ]
                        ],
                        "navigationEndpoint": [
                            "browseEndpoint": [
                                "browseId": browseID,
                                "browseEndpointContextSupportedConfigs": [
                                    "browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_ALBUM"]
                                ]
                            ]
                        ]
                    ]
                ]]
            ]
        ]
    }

    private static func chartShelf() -> [String: Any] {
        func card(title: String, subtitle: String, browseID: String) -> [String: Any] {
            [
                "musicTwoRowItemRenderer": [
                    "title": ["runs": [["text": title]]],
                    "subtitle": ["runs": [["text": subtitle]]],
                    "thumbnailRenderer": [
                        "musicThumbnailRenderer": [
                            "thumbnail": ["thumbnails": [["url": "https://img.example/chart.jpg"]]]
                        ]
                    ],
                    "navigationEndpoint": [
                        "browseEndpoint": [
                            "browseId": browseID,
                            "browseEndpointContextSupportedConfigs": [
                                "browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_PLAYLIST"]
                            ]
                        ]
                    ]
                ]
            ]
        }
        return [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": "Daily charts"]]]
                    ]
                ],
                "contents": [
                    card(
                        title: "Trending 20 United States",
                        subtitle: "Chart • YouTube Music",
                        browseID: "VL-trending"
                    ),
                    card(
                        title: "Daily Top Music Videos - United States",
                        subtitle: "Videos • YouTube Music",
                        browseID: "VL-videos"
                    )
                ]
            ]
        ]
    }

    private static func artistChartShelf(title: String, browseID: String) -> [String: Any] {
        [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": title]]]
                    ]
                ],
                "contents": [[
                    "musicResponsiveListItemRenderer": [
                        "flexColumns": [
                            ["musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "Chart Artist"]]]
                            ]],
                            ["musicResponsiveListItemFlexColumnRenderer": [
                                "text": ["runs": [["text": "12M subscribers"]]]
                            ]]
                        ],
                        "thumbnail": [
                            "musicThumbnailRenderer": [
                                "thumbnail": ["thumbnails": [["url": "https://img.example/artist.jpg"]]]
                            ]
                        ],
                        "navigationEndpoint": [
                            "browseEndpoint": [
                                "browseId": browseID,
                                "browseEndpointContextSupportedConfigs": [
                                    "browseEndpointContextMusicConfig": ["pageType": "MUSIC_PAGE_TYPE_ARTIST"]
                                ]
                            ]
                        ]
                    ]
                ]]
            ]
        ]
    }

    private static func searchTrackRow(
        videoID: String,
        title: String,
        artist: String,
        duration: String,
        rowType: String = "Song",
        width: Int = 226,
        height: Int = 226
    ) -> [String: Any] {
        [
            "musicResponsiveListItemRenderer": [
                "playlistItemData": ["videoId": videoID],
                "flexColumns": [
                    ["musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": title]]]
                    ]],
                    ["musicResponsiveListItemFlexColumnRenderer": [
                        "text": ["runs": [["text": "\(rowType) • \(artist)"]]]
                    ]]
                ],
                "fixedColumns": [[
                    "musicResponsiveListItemFixedColumnRenderer": [
                        "text": ["runs": [["text": duration]]]
                    ]
                ]],
                "thumbnail": [
                    "musicThumbnailRenderer": [
                        "thumbnail": [
                            "thumbnails": [[
                                "url": "https://example.com/\(videoID).jpg",
                                "width": width,
                                "height": height
                            ]]
                        ]
                    ]
                ]
            ]
        ]
    }

    private static func homeVideoCard(videoID: String, title: String, subtitle: String) -> [String: Any] {
        [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": title]]],
                "subtitle": ["runs": [["text": subtitle]]],
                "navigationEndpoint": ["watchEndpoint": ["videoId": videoID]],
                "thumbnailRenderer": [
                    "musicThumbnailRenderer": [
                        "thumbnail": [
                            "thumbnails": [[
                                "url": "https://example.com/\(videoID).jpg",
                                "width": 544,
                                "height": 304
                            ]]
                        ]
                    ]
                ]
            ]
        ]
    }

    private static func creditRun(text: String, browseID: String, pageType: String) -> [String: Any] {
        [
            "text": text,
            "navigationEndpoint": [
                "browseEndpoint": [
                    "browseId": browseID,
                    "browseEndpointContextSupportedConfigs": [
                        "browseEndpointContextMusicConfig": ["pageType": pageType]
                    ]
                ]
            ]
        ]
    }

    private static func response(
        for request: URLRequest,
        json: [String: Any]
    ) -> (HTTPURLResponse, Data) {
        response(for: request, data: try! JSONSerialization.data(withJSONObject: json))
    }

    private static func response(
        for request: URLRequest,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: YouTubeMusicAPIError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
