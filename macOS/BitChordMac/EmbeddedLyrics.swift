import Foundation

@MainActor
protocol DownloadLyricsProviding: AnyObject {
    func lyricsForDownload(_ track: Track) async -> Lyrics?
}

extension YouTubeMusicAPI: DownloadLyricsProviding {
    func lyricsForDownload(_ track: Track) async -> Lyrics? {
        try? await lyrics(for: track)
    }
}

struct DownloadArtwork: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int
    let depth: Int
}

@MainActor
protocol DownloadArtworkProviding: AnyObject {
    func artworkForDownload(_ track: Track) async -> DownloadArtwork?
}

/// Reads and writes the same two lyric fields as the Kotlin download path:
/// portable line-synced LRC plus a BitChord-only enhanced LRC copy that keeps
/// word timing. Metadata failures never make an otherwise valid download fail.
enum EmbeddedLyricsStore {
    static let wordLyricsField = "BITCHORD_LYRICS"
    static let maximumLRCCharacters = 64_000

    struct Documents: Equatable, Sendable {
        let plain: String
        let enhanced: String?
    }

    fileprivate struct MediaMetadata: Sendable {
        let title: String
        let artist: String
        let album: String?
        let artwork: DownloadArtwork?
    }

    static func documents(for lyrics: Lyrics) -> Documents? {
        let useful = lyrics.lines.filter { !$0.text.isEmpty || $0.background?.text.isEmpty == false }
        guard !useful.isEmpty else { return nil }

        let sorted = useful.sorted { $0.start < $1.start }
        let plain = sorted.map { line in
            "[\(clock(line.start))]\(flattened(line))"
        }.joined(separator: "\n")
        guard !plain.isEmpty, plain.count <= maximumLRCCharacters else { return nil }

        let hasWordTiming = sorted.contains {
            !$0.words.isEmpty || $0.background?.words.isEmpty == false
        }
        let enhanced = hasWordTiming
            ? sorted.map { line in "[\(clock(line.start))]\(enhancedBody(line))" }.joined(separator: "\n")
            : nil
        return Documents(
            plain: plain,
            enhanced: enhanced.flatMap {
                $0.isEmpty || $0.count > maximumLRCCharacters * 2 ? nil : $0
            }
        )
    }

    static func embed(_ lyrics: Lyrics, in fileURL: URL) async -> Bool {
        guard let documents = documents(for: lyrics) else { return false }
        return await Task.detached(priority: .utility) {
            embed(metadata: nil, documents: documents, in: fileURL)
        }.value
    }

    /// Android tags every completed download, including direct JioSaavn and
    /// module streams that arrive without container metadata. Keep the same
    /// operation atomic here so a file is never published with lyrics but no
    /// title/artist/album identity.
    static func embed(
        track: Track,
        lyrics: Lyrics?,
        artwork: DownloadArtwork?,
        in fileURL: URL
    ) async -> Bool {
        let metadata = MediaMetadata(
            title: track.title,
            artist: track.artist,
            album: track.album,
            artwork: artwork
        )
        let documents = lyrics.flatMap(documents(for:))
        return await Task.detached(priority: .utility) {
            embed(metadata: metadata, documents: documents, in: fileURL)
        }.value
    }

    static func load(from fileURL: URL) async -> Lyrics? {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
            let raw: String?
            if data.starts(with: Data("fLaC".utf8)) {
                raw = FLAC.read(data)
            } else {
                raw = MP4.read(data)
            }
            guard let raw, !raw.isEmpty else { return nil }
            let lines = LyricsParsers.withBackgroundVocals(LyricsParsers.parseLRC(raw))
            guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
            return Lyrics(lines: lines, source: "Embedded")
        }.value
    }

    private static func embed(
        metadata: MediaMetadata?,
        documents: Documents?,
        in fileURL: URL
    ) -> Bool {
        guard let original = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return false }
        let rewritten: Data
        if original.starts(with: Data("fLaC".utf8)) {
            rewritten = FLAC.write(metadata: metadata, documents: documents, to: original)
        } else {
            rewritten = MP4.write(metadata: metadata, documents: documents, to: original)
        }
        guard rewritten != original else { return false }
        do {
            try rewritten.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func flattened(_ line: LyricLine) -> String {
        guard let background = line.background, !background.text.isEmpty else { return line.text }
        return "\(line.text) \(background.text)".trimmingCharacters(in: .whitespaces)
    }

    private static func enhancedBody(_ line: LyricLine) -> String {
        guard !line.words.isEmpty else { return flattened(line) }
        var runs = line.words
        if let background = line.background {
            if !background.words.isEmpty {
                runs.append(contentsOf: background.words)
            } else if !background.text.isEmpty {
                runs.append(LyricWord(
                    start: background.start,
                    end: background.end ?? background.start,
                    text: background.text
                ))
            }
        }

        var previous = line.start
        var pieces: [String] = []
        for run in runs {
            let start = max(run.start, previous)
            pieces.append("<\(clock(start))>\(run.text)")
            previous = start
        }
        let end = max(runs.map(\.end).max() ?? previous, previous)
        return pieces.joined(separator: " ") + "<\(clock(end))>"
    }

    private static func clock(_ time: TimeInterval) -> String {
        let centiseconds = max(0, Int((time * 100).rounded(.down)))
        let minutes = centiseconds / 6_000
        let seconds = (centiseconds % 6_000) / 100
        let fraction = centiseconds % 100
        return String(format: "%02d:%02d.%02d", minutes, seconds, fraction)
    }
}

private enum MP4 {
    private struct Box {
        let offset: Int
        let headerLength: Int
        let size: Int
        let rawSize: UInt64
        let type: [UInt8]

        var contentOffset: Int { offset + headerLength }
        var end: Int { offset + size }
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
    private static let copyrightName: [UInt8] = [0xA9, 0x6E, 0x61, 0x6D]
    private static let copyrightArtist: [UInt8] = [0xA9, 0x41, 0x52, 0x54]
    private static let copyrightAlbum: [UInt8] = [0xA9, 0x61, 0x6C, 0x62]
    private static let copyrightLyrics: [UInt8] = [0xA9, 0x6C, 0x79, 0x72]

    static func write(
        metadata: EmbeddedLyricsStore.MediaMetadata?,
        documents: EmbeddedLyricsStore.Documents?,
        to bytes: Data
    ) -> Data {
        guard let moov = boxes(in: bytes, from: 0, to: bytes.count).first(where: { ascii($0.type) == "moov" }) else {
            return bytes
        }
        var items: [Data] = []
        if let metadata {
            if !metadata.title.isEmpty { items.append(textItem(type: copyrightName, text: metadata.title)) }
            if !metadata.artist.isEmpty { items.append(textItem(type: copyrightArtist, text: metadata.artist)) }
            if let album = metadata.album, !album.isEmpty {
                items.append(textItem(type: copyrightAlbum, text: album))
            }
            if let artwork = metadata.artwork, !artwork.data.isEmpty {
                items.append(coverItem(artwork))
            }
        }
        if let documents {
            items.append(textItem(type: copyrightLyrics, text: documents.plain))
        }
        if let enhanced = documents?.enhanced {
            items.append(freeformItem(name: EmbeddedLyricsStore.wordLyricsField, text: enhanced))
        }
        guard !items.isEmpty else { return bytes }
        return insert(udta(meta(ilst(items))), into: moov, in: bytes)
    }

    static func read(_ bytes: Data) -> String? {
        guard let moov = boxes(in: bytes, from: 0, to: bytes.count).first(where: { ascii($0.type) == "moov" }) else {
            return nil
        }
        let range = moov.offset..<moov.end
        if let nameRange = bytes.range(of: Data(EmbeddedLyricsStore.wordLyricsField.utf8), options: [], in: range),
           let dataRange = bytes.range(of: Data("data".utf8), options: [], in: nameRange.upperBound..<range.upperBound),
           let text = dataText(bytes, typeOffset: dataRange.lowerBound), !text.isEmpty {
            return text
        }
        if let itemRange = bytes.range(of: Data(copyrightLyrics), options: [], in: range),
           let dataRange = bytes.range(of: Data("data".utf8), options: [], in: itemRange.upperBound..<range.upperBound) {
            return dataText(bytes, typeOffset: dataRange.lowerBound)
        }
        return nil
    }

    private static func insert(_ payload: Data, into moov: Box, in bytes: Data) -> Data {
        let insertion = moov.end
        let delta = payload.count
        var prefix = Data(bytes[..<insertion])
        if moov.rawSize != 0 {
            if moov.headerLength == 16 {
                writeU64(&prefix, at: moov.offset + 8, value: UInt64(moov.size + delta))
            } else {
                writeU32(&prefix, at: moov.offset, value: UInt32(moov.size + delta))
            }
        }

        var offsetBoxes: [Box] = []
        collectOffsetBoxes(in: bytes, box: moov, result: &offsetBoxes)
        for box in offsetBoxes {
            patchOffsets(in: &prefix, box: box, insertion: insertion, delta: delta)
        }
        var result = prefix
        result.append(payload)
        result.append(contentsOf: bytes[insertion...])
        return result
    }

    private static func collectOffsetBoxes(in bytes: Data, box: Box, result: inout [Box]) {
        let type = ascii(box.type)
        if type == "stco" || type == "co64" {
            result.append(box)
            return
        }
        guard containers.contains(type) else { return }
        for child in boxes(in: bytes, from: box.contentOffset, to: box.end) {
            collectOffsetBoxes(in: bytes, box: child, result: &result)
        }
    }

    private static func patchOffsets(in bytes: inout Data, box: Box, insertion: Int, delta: Int) {
        let countOffset = box.contentOffset + 4
        guard countOffset + 4 <= bytes.count else { return }
        let count = Int(readU32(bytes, at: countOffset))
        var cursor = countOffset + 4
        for _ in 0..<count {
            if ascii(box.type) == "stco" {
                guard cursor + 4 <= bytes.count else { return }
                let value = readU32(bytes, at: cursor)
                if UInt64(value) >= UInt64(insertion) {
                    writeU32(&bytes, at: cursor, value: UInt32(Int(value) + delta))
                }
                cursor += 4
            } else {
                guard cursor + 8 <= bytes.count else { return }
                let value = readU64(bytes, at: cursor)
                if value >= UInt64(insertion) {
                    writeU64(&bytes, at: cursor, value: value + UInt64(delta))
                }
                cursor += 8
            }
        }
    }

    private static func boxes(in bytes: Data, from start: Int, to end: Int) -> [Box] {
        var result: [Box] = []
        var cursor = start
        while cursor + 8 <= end {
            let size32 = UInt64(readU32(bytes, at: cursor))
            let type = Array(bytes[(cursor + 4)..<(cursor + 8)])
            var headerLength = 8
            var size = size32
            if size32 == 1 {
                guard cursor + 16 <= end else { break }
                size = readU64(bytes, at: cursor + 8)
                headerLength = 16
            } else if size32 == 0 {
                size = UInt64(end - cursor)
            }
            guard size >= UInt64(headerLength), size <= UInt64(Int.max), cursor + Int(size) <= end else { break }
            result.append(Box(
                offset: cursor,
                headerLength: headerLength,
                size: Int(size),
                rawSize: size32,
                type: type
            ))
            cursor += Int(size)
        }
        return result
    }

    private static func textItem(type: [UInt8], text: String) -> Data {
        box(type: type, payload: dataAtom(type: 1, payload: Data(text.utf8)))
    }

    private static func coverItem(_ artwork: DownloadArtwork) -> Data {
        let type: UInt32 = artwork.mimeType.caseInsensitiveCompare("image/png") == .orderedSame ? 14 : 13
        return box(type: Array("covr".utf8), payload: dataAtom(type: type, payload: artwork.data))
    }

    private static func freeformItem(name: String, text: String) -> Data {
        var meanPayload = Data(repeating: 0, count: 4)
        meanPayload.append(Data("com.music.bitchord".utf8))
        var namePayload = Data(repeating: 0, count: 4)
        namePayload.append(Data(name.utf8))
        var payload = box(type: Array("mean".utf8), payload: meanPayload)
        payload.append(box(type: Array("name".utf8), payload: namePayload))
        payload.append(dataAtom(type: 1, payload: Data(text.utf8)))
        return box(type: Array("----".utf8), payload: payload)
    }

    private static func dataAtom(type: UInt32, payload: Data) -> Data {
        var body = Data(repeating: 0, count: 8)
        writeU32(&body, at: 0, value: type)
        body.append(payload)
        return box(type: Array("data".utf8), payload: body)
    }

    private static func ilst(_ items: [Data]) -> Data {
        box(type: Array("ilst".utf8), payload: items.reduce(into: Data()) { $0.append($1) })
    }

    private static func meta(_ ilst: Data) -> Data {
        var handler = Data(repeating: 0, count: 25)
        handler.replaceSubrange(8..<12, with: Data("mdir".utf8))
        var payload = Data(repeating: 0, count: 4)
        payload.append(box(type: Array("hdlr".utf8), payload: handler))
        payload.append(ilst)
        return box(type: Array("meta".utf8), payload: payload)
    }

    private static func udta(_ meta: Data) -> Data {
        box(type: Array("udta".utf8), payload: meta)
    }

    private static func box(type: [UInt8], payload: Data) -> Data {
        guard type.count == 4, payload.count <= Int(UInt32.max) - 8 else { return Data() }
        var result = Data(repeating: 0, count: 8)
        writeU32(&result, at: 0, value: UInt32(payload.count + 8))
        result.replaceSubrange(4..<8, with: type)
        result.append(payload)
        return result
    }

    private static func dataText(_ bytes: Data, typeOffset: Int) -> String? {
        let boxStart = typeOffset - 4
        guard boxStart >= 0, typeOffset + 12 <= bytes.count else { return nil }
        let size = Int(readU32(bytes, at: boxStart))
        guard size > 16, boxStart + size <= bytes.count,
              readU32(bytes, at: typeOffset + 4) == 1 else { return nil }
        return String(data: Data(bytes[(typeOffset + 12)..<(boxStart + size)]), encoding: .utf8)
    }

    private static func ascii(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }
}

private enum FLAC {
    private struct Block {
        let type: Int
        let payload: Data
    }

    static func write(
        metadata: EmbeddedLyricsStore.MediaMetadata?,
        documents: EmbeddedLyricsStore.Documents?,
        to bytes: Data
    ) -> Data {
        guard let parsed = parse(bytes) else { return bytes }
        var fields = parsed.blocks
            .first(where: { $0.type == 4 })
            .flatMap { comments($0.payload)?.fields } ?? []
        fields.removeAll { field in
            let name = field.split(separator: "=", maxSplits: 1).first?.uppercased() ?? ""
            return ["TITLE", "ARTIST", "ALBUM", "LYRICS", EmbeddedLyricsStore.wordLyricsField].contains(name)
        }
        if let metadata {
            if !metadata.title.isEmpty { fields.append("TITLE=\(metadata.title)") }
            if !metadata.artist.isEmpty { fields.append("ARTIST=\(metadata.artist)") }
            if let album = metadata.album, !album.isEmpty { fields.append("ALBUM=\(album)") }
        }
        if let documents { fields.append("LYRICS=\(documents.plain)") }
        if let enhanced = documents?.enhanced {
            fields.append("\(EmbeddedLyricsStore.wordLyricsField)=\(enhanced)")
        }
        let vendor = parsed.blocks.first(where: { $0.type == 4 })
            .flatMap { comments($0.payload)?.vendor } ?? "Lilt"
        let comment = commentPayload(vendor: vendor, fields: fields)
        guard comment.count < 1 << 24 else { return bytes }

        var blocks = parsed.blocks.filter {
            $0.type != 4 && !(metadata?.artwork != nil && $0.type == 6)
        }
        blocks.insert(Block(type: 4, payload: comment), at: min(1, blocks.count))
        if let artwork = metadata?.artwork, !artwork.data.isEmpty {
            blocks.insert(
                Block(type: 6, payload: picturePayload(artwork)),
                at: min(2, blocks.count)
            )
        }
        var result = Data("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            result.append(UInt8(block.type | (index == blocks.count - 1 ? 0x80 : 0)))
            result.append(UInt8((block.payload.count >> 16) & 0xFF))
            result.append(UInt8((block.payload.count >> 8) & 0xFF))
            result.append(UInt8(block.payload.count & 0xFF))
            result.append(block.payload)
        }
        result.append(contentsOf: bytes[parsed.framesOffset...])
        return result
    }

    static func read(_ bytes: Data) -> String? {
        guard let parsed = parse(bytes),
              let payload = parsed.blocks.first(where: { $0.type == 4 })?.payload,
              let parsedComments = comments(payload) else { return nil }
        for name in [EmbeddedLyricsStore.wordLyricsField, "LYRICS"] {
            if let field = parsedComments.fields.first(where: {
                $0.uppercased().hasPrefix(name + "=")
            }), let separator = field.firstIndex(of: "=") {
                let value = String(field[field.index(after: separator)...])
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    private static func parse(_ bytes: Data) -> (blocks: [Block], framesOffset: Int)? {
        guard bytes.starts(with: Data("fLaC".utf8)) else { return nil }
        var blocks: [Block] = []
        var cursor = 4
        while cursor + 4 <= bytes.count {
            let flag = Int(bytes[cursor])
            let length = Int(bytes[cursor + 1]) << 16 | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
            let start = cursor + 4
            guard start + length <= bytes.count else { return nil }
            blocks.append(Block(type: flag & 0x7F, payload: Data(bytes[start..<(start + length)])))
            cursor = start + length
            if flag & 0x80 != 0 { break }
        }
        guard blocks.first?.type == 0 else { return nil }
        return (blocks, cursor)
    }

    private static func comments(_ payload: Data) -> (vendor: String, fields: [String])? {
        var cursor = 0
        guard let vendorLength = readLE(payload, cursor), vendorLength >= 0 else { return nil }
        cursor += 4
        guard cursor + vendorLength <= payload.count,
              let vendor = String(data: Data(payload[cursor..<(cursor + vendorLength)]), encoding: .utf8) else { return nil }
        cursor += vendorLength
        guard let count = readLE(payload, cursor), count >= 0 else { return nil }
        cursor += 4
        var fields: [String] = []
        for _ in 0..<count {
            guard let length = readLE(payload, cursor), length >= 0 else { return nil }
            cursor += 4
            guard cursor + length <= payload.count,
                  let field = String(data: Data(payload[cursor..<(cursor + length)]), encoding: .utf8) else { return nil }
            fields.append(field)
            cursor += length
        }
        return (vendor, fields)
    }

    private static func commentPayload(vendor: String, fields: [String]) -> Data {
        var result = Data()
        appendLE(Data(vendor.utf8).count, to: &result)
        result.append(Data(vendor.utf8))
        appendLE(fields.count, to: &result)
        for field in fields {
            let data = Data(field.utf8)
            appendLE(data.count, to: &result)
            result.append(data)
        }
        return result
    }

    private static func picturePayload(_ artwork: DownloadArtwork) -> Data {
        var result = Data()
        appendBE(3, to: &result) // front cover
        let mime = Data(artwork.mimeType.utf8)
        appendBE(UInt32(mime.count), to: &result)
        result.append(mime)
        appendBE(0, to: &result) // empty description
        appendBE(UInt32(max(0, artwork.width)), to: &result)
        appendBE(UInt32(max(0, artwork.height)), to: &result)
        appendBE(UInt32(max(0, artwork.depth)), to: &result)
        appendBE(0, to: &result) // indexed colours
        appendBE(UInt32(artwork.data.count), to: &result)
        result.append(artwork.data)
        return result
    }

    private static func appendBE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func readLE(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return Int(data[offset]) | Int(data[offset + 1]) << 8 |
            Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }

    private static func appendLE(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

private func readU32(_ data: Data, at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { return 0 }
    return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
        UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
}

private func readU64(_ data: Data, at offset: Int) -> UInt64 {
    guard offset >= 0, offset + 8 <= data.count else { return 0 }
    var value: UInt64 = 0
    for index in 0..<8 { value = value << 8 | UInt64(data[offset + index]) }
    return value
}

private func writeU32(_ data: inout Data, at offset: Int, value: UInt32) {
    guard offset >= 0, offset + 4 <= data.count else { return }
    data[offset] = UInt8((value >> 24) & 0xFF)
    data[offset + 1] = UInt8((value >> 16) & 0xFF)
    data[offset + 2] = UInt8((value >> 8) & 0xFF)
    data[offset + 3] = UInt8(value & 0xFF)
}

private func writeU64(_ data: inout Data, at offset: Int, value: UInt64) {
    guard offset >= 0, offset + 8 <= data.count else { return }
    for index in 0..<8 {
        data[offset + index] = UInt8((value >> UInt64(8 * (7 - index))) & 0xFF)
    }
}
