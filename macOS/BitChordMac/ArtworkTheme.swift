import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

struct ArtworkRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    var color: Color { Color(red: red, green: green, blue: blue) }

    var hue: Double { hsl.hue }
    var saturation: Double { hsl.saturation }
    var lightness: Double { hsl.lightness }

    func adjusted(
        saturation transformSaturation: (Double) -> Double = { $0 },
        lightness transformLightness: (Double) -> Double = { $0 }
    ) -> ArtworkRGB {
        let value = hsl
        return ArtworkRGB(
            hue: value.hue,
            saturation: min(max(transformSaturation(value.saturation), 0), 1),
            lightness: min(max(transformLightness(value.lightness), 0), 1)
        )
    }

    private var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        guard delta > 0.000_001 else { return (0, 0, lightness) }

        let saturation = delta / (1 - abs(2 * lightness - 1))
        let rawHue: Double
        switch maximum {
        case red:
            rawHue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        case green:
            rawHue = (blue - red) / delta + 2
        default:
            rawHue = (red - green) / delta + 4
        }
        let normalizedHue = (rawHue / 6).truncatingRemainder(dividingBy: 1)
        return (normalizedHue < 0 ? normalizedHue + 1 : normalizedHue, saturation, lightness)
    }

    private init(hue: Double, saturation: Double, lightness: Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue * 6
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let component: (Double, Double, Double)
        switch sector {
        case 0..<1: component = (chroma, x, 0)
        case 1..<2: component = (x, chroma, 0)
        case 2..<3: component = (0, chroma, x)
        case 3..<4: component = (0, x, chroma)
        case 4..<5: component = (x, 0, chroma)
        default: component = (chroma, 0, x)
        }
        let match = lightness - chroma / 2
        self.init(red: component.0 + match, green: component.1 + match, blue: component.2 + match)
    }
}

struct ArtworkThemeColors: Equatable, Sendable {
    let background: ArtworkRGB
    let wash: ArtworkRGB
    let elevated: ArtworkRGB
    let accent: ArtworkRGB

    var backgroundColor: Color { background.color }
    var washColor: Color { wash.color }
    var elevatedColor: Color { elevated.color }
    var accentColor: Color { accent.color }
    var onBackgroundColor: Color { .white }
    var secondaryTextColor: Color { .white.opacity(0.78) }
    var dividerColor: Color { .white.opacity(0.12) }

    static let fallback = ArtworkThemeColors(
        background: ArtworkRGB(red: 0.055, green: 0.035, blue: 0.09),
        wash: ArtworkRGB(red: 0.16, green: 0.08, blue: 0.24),
        elevated: ArtworkRGB(red: 0.14, green: 0.08, blue: 0.20),
        accent: ArtworkRGB(red: 0.88, green: 0.30, blue: 0.92)
    )
}

struct ArtworkThemeExtractor {
    private struct Bucket {
        var count = 0
        var red = 0
        var green = 0
        var blue = 0

        mutating func add(red: UInt8, green: UInt8, blue: UInt8) {
            count += 1
            self.red += Int(red)
            self.green += Int(green)
            self.blue += Int(blue)
        }

        var color: ArtworkRGB {
            let divisor = max(count, 1)
            return ArtworkRGB(
                red: UInt8(red / divisor),
                green: UInt8(green / divisor),
                blue: UInt8(blue / divisor)
            )
        }
    }

    private static let sampleSide = 64
    private static let edgeFraction = 0.18

    static func colors(from imageData: Data) -> ArtworkThemeColors? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: sampleSide
              ] as CFDictionary) else { return nil }

        var rgba = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleSide,
                height: sampleSide,
                bitsPerComponent: 8,
                bytesPerRow: sampleSide * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleSide, height: sampleSide))
            return true
        }
        guard rendered else { return nil }
        return colors(fromRGBA: rgba, width: sampleSide, height: sampleSide)
    }

    static func colors(fromRGBA rgba: [UInt8], width: Int, height: Int) -> ArtworkThemeColors? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var buckets: [Int: Bucket] = [:]
        buckets.reserveCapacity(256)

        for pixel in stride(from: 0, to: width * height * 4, by: 4) {
            guard rgba[pixel + 3] >= 96 else { continue }
            let red = rgba[pixel]
            let green = rgba[pixel + 1]
            let blue = rgba[pixel + 2]
            let key = (Int(red >> 4) << 8) | (Int(green >> 4) << 4) | Int(blue >> 4)
            buckets[key, default: Bucket()].add(red: red, green: green, blue: blue)
        }
        guard let dominantBucket = buckets.values.max(by: { $0.count < $1.count }) else { return nil }

        let vibrantBucket = buckets.values.max { left, right in
            vibrantScore(left) < vibrantScore(right)
        } ?? dominantBucket

        let bandHeight = min(max(Int((Double(height) * edgeFraction).rounded()), 1), height)
        let firstEdgeRow = height - bandHeight
        var edgeRed = 0
        var edgeGreen = 0
        var edgeBlue = 0
        var edgeCount = 0
        for row in firstEdgeRow..<height {
            for column in 0..<width {
                let pixel = (row * width + column) * 4
                guard rgba[pixel + 3] >= 96 else { continue }
                edgeRed += Int(rgba[pixel])
                edgeGreen += Int(rgba[pixel + 1])
                edgeBlue += Int(rgba[pixel + 2])
                edgeCount += 1
            }
        }
        let edge = edgeCount > 0
            ? ArtworkRGB(
                red: UInt8(edgeRed / edgeCount),
                green: UInt8(edgeGreen / edgeCount),
                blue: UInt8(edgeBlue / edgeCount)
            )
            : dominantBucket.color

        return palette(dominant: dominantBucket.color, vibrant: vibrantBucket.color, edge: edge)
    }

    private static func vibrantScore(_ bucket: Bucket) -> Double {
        bucket.color.saturation * sqrt(Double(bucket.count))
    }

    private static func palette(
        dominant: ArtworkRGB,
        vibrant: ArtworkRGB,
        edge: ArtworkRGB
    ) -> ArtworkThemeColors {
        ArtworkThemeColors(
            background: dominant.adjusted(
                saturation: { min(max($0, 0.20), 0.62) },
                lightness: { _ in 0.13 }
            ),
            wash: edge.adjusted(
                saturation: { min(max($0, 0.18), 0.58) },
                lightness: { min(max($0, 0.14), 0.24) }
            ),
            elevated: dominant.adjusted(
                saturation: { min(max($0, 0.20), 0.62) },
                lightness: { _ in 0.22 }
            ),
            accent: vibrant.adjusted(
                saturation: { max($0, 0.55) },
                lightness: { min(max($0, 0.62), 0.78) }
            )
        )
    }
}

@MainActor
final class ArtworkThemeLoader: ObservableObject {
    @Published private(set) var colors = ArtworkThemeColors.fallback

    private final class CacheEntry {
        let colors: ArtworkThemeColors
        init(_ colors: ArtworkThemeColors) { self.colors = colors }
    }

    private static let cache: NSCache<NSString, CacheEntry> = {
        let cache = NSCache<NSString, CacheEntry>()
        cache.countLimit = 128
        return cache
    }()

    private var requestKey: String?

    func load(urlString: String?, enabled: Bool) async {
        guard enabled, let urlString, let url = URL(string: urlString) else {
            requestKey = nil
            colors = .fallback
            return
        }
        guard requestKey != urlString else { return }
        requestKey = urlString

        if let cached = Self.cache.object(forKey: urlString as NSString) {
            colors = cached.colors
            return
        }
        colors = .fallback

        do {
            let data: Data
            if url.isFileURL {
                data = try await Task.detached(priority: .utility) {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
            } else {
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                request.timeoutInterval = 15
                let result = try await URLSession.shared.data(for: request)
                guard let http = result.1 as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { return }
                data = result.0
            }
            guard data.count <= 12 * 1_024 * 1_024 else { return }
            let extracted = await Task.detached(priority: .utility) {
                ArtworkThemeExtractor.colors(from: data)
            }.value
            try Task.checkCancellation()
            guard requestKey == urlString, let extracted else { return }
            Self.cache.setObject(CacheEntry(extracted), forKey: urlString as NSString)
            colors = extracted
        } catch {
            guard !Task.isCancelled, requestKey == urlString else { return }
            colors = .fallback
        }
    }
}

struct ArtworkThemeBackdrop: View {
    let colors: ArtworkThemeColors
    let reduceAnimation: Bool
    let reduceDynamicBlur: Bool
    @State private var shifted = false

    var body: some View {
        ZStack {
            colors.backgroundColor
            LinearGradient(
                colors: reduceDynamicBlur
                    ? [colors.elevatedColor, colors.backgroundColor, .black.opacity(0.88)]
                    : [colors.washColor.opacity(0.92), colors.backgroundColor, .black.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if !reduceDynamicBlur {
                Circle()
                    .fill(RadialGradient(
                        colors: [colors.accentColor.opacity(0.42), colors.accentColor.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 310
                    ))
                    .frame(width: 620, height: 620)
                    .blur(radius: 55)
                    .offset(x: shifted ? -260 : 230, y: shifted ? -170 : 160)
                Circle()
                    .fill(RadialGradient(
                        colors: [colors.washColor.opacity(0.62), colors.washColor.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 270
                    ))
                    .frame(width: 540, height: 540)
                    .blur(radius: 65)
                    .offset(x: shifted ? 300 : -250, y: shifted ? 190 : -200)
            }
            Rectangle().fill(.black.opacity(0.18))
        }
        .animation(.easeInOut(duration: 0.65), value: colors)
        .animation(.easeOut(duration: 0.2), value: reduceDynamicBlur)
        .onAppear { updateMotion() }
        .onChange(of: reduceAnimation) { _ in updateMotion() }
        .onChange(of: reduceDynamicBlur) { _ in updateMotion() }
    }

    private func updateMotion() {
        if reduceAnimation || reduceDynamicBlur {
            shifted = false
        } else {
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) {
                shifted = true
            }
        }
    }
}
