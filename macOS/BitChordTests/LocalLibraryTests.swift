import AVFoundation
import Foundation
import XCTest

final class LocalLibraryTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUp() async throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitChordLocalLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testLegacyTrackArrayMigratesToVersionedLibraryState() throws {
        let track = Track(
            videoID: nil,
            title: "Legacy Song",
            artist: "Legacy Artist",
            album: "Legacy Album",
            artworkURL: nil,
            duration: 42,
            localPath: "/tmp/legacy.m4a",
            sourceURL: nil
        )

        let data = try JSONEncoder().encode([track])
        let state = try XCTUnwrap(LocalLibraryPersistence.decode(data))

        XCTAssertEqual(state.version, 2)
        XCTAssertEqual(state.importedTracks, [track])
        XCTAssertTrue(state.folders.isEmpty)
    }

    func testOrganizerBuildsArtistAlbumAndFolderCollections() throws {
        let folder = LocalLibraryFolder(url: URL(fileURLWithPath: "/Music/Local QA", isDirectory: true))
        let tracks = [
            makeTrack(title: "First", artist: "BitChord QA", album: "Native Album", path: "/Music/Local QA/first.m4a", folderID: folder.id),
            makeTrack(title: "Second", artist: "BitChord QA", album: "Native Album", path: "/Music/Local QA/second.m4a", folderID: folder.id),
            makeTrack(title: "Elsewhere", artist: "Another Artist", album: nil, path: "/tmp/elsewhere.wav", folderID: nil)
        ]

        let artists = LocalLibraryOrganizer.collections(kind: .artist, tracks: tracks, folders: [folder])
        let albums = LocalLibraryOrganizer.collections(kind: .album, tracks: tracks, folders: [folder])
        let folders = LocalLibraryOrganizer.collections(kind: .folder, tracks: tracks, folders: [folder])

        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists.first(where: { $0.title == "BitChord QA" })?.tracks.count, 2)
        XCTAssertEqual(albums.map(\.title), ["Native Album"])
        XCTAssertEqual(folders.first?.tracks.count, 2)
        XCTAssertEqual(folders.first?.folderID, folder.id)
        XCTAssertEqual(LocalLibraryOrganizer.filtered(tracks, query: "native").count, 2)
    }

    func testRecursiveIndexerReadsDurationAndCachesSiblingArtwork() async throws {
        let music = temporaryRoot.appendingPathComponent("Music", isDirectory: true)
        let nested = music.appendingPathComponent("Album/Disc 1", isDirectory: true)
        let artwork = temporaryRoot.appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try makeSilentWAV(at: nested.appendingPathComponent("Fixture.wav"), seconds: 6)
        try Data("not audio".utf8).write(to: nested.appendingPathComponent("notes.txt"))
        try Data(base64Encoded: Self.onePixelPNG)!.write(to: nested.appendingPathComponent("cover.png"))
        try makeSilentWAV(at: nested.appendingPathComponent(".hidden.wav"), seconds: 6)

        let folder = LocalLibraryFolder(url: music)
        let tracks = await LocalMediaIndexer(artworkDirectory: artwork).tracks(in: folder)

        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(track.title, "Fixture")
        XCTAssertEqual(track.artist, "Unknown Artist")
        XCTAssertEqual(track.localFolderID, folder.id)
        XCTAssertEqual(try XCTUnwrap(track.duration), 6, accuracy: 0.1)
        let artworkURL = try XCTUnwrap(track.artworkURL.flatMap(URL.init(string:)))
        XCTAssertTrue(artworkURL.isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkURL.path))
    }

    private func makeTrack(
        title: String,
        artist: String,
        album: String?,
        path: String,
        folderID: String?
    ) -> Track {
        Track(
            videoID: nil,
            title: title,
            artist: artist,
            album: album,
            artworkURL: nil,
            duration: 180,
            localPath: path,
            sourceURL: nil,
            localFolderID: folderID
        )
    }

    private func makeSilentWAV(at url: URL, seconds: Double) throws {
        let sampleRate = 8_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?.pointee {
            channel.initialize(repeating: 0, count: Int(frames))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}
