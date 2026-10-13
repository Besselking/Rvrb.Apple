import CryptoKit
import ImageIO
import SwiftUI

/// An image from a URL or from embedded data (chat images can be `data:` URIs). GIF, WebP and APNG files animate
/// at their own frame timing (`AsyncImage` shows only the first frame). Decoded images are cached in memory and
/// downsampled to `maxPixelSize`.
struct RemoteImage<Placeholder: View>: View {
    let source: ChatText.Image?
    /// The largest side to decode to, in pixels (the displayed size times the screen scale is plenty).
    var maxPixelSize: CGFloat = 512
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: (_ failed: Bool) -> Placeholder

    init(url: URL?, maxPixelSize: CGFloat = 512, contentMode: ContentMode = .fill,
         @ViewBuilder placeholder: @escaping (_ failed: Bool) -> Placeholder) {
        self.init(source: url.map(ChatText.Image.url), maxPixelSize: maxPixelSize, contentMode: contentMode,
                  placeholder: placeholder)
    }

    init(source: ChatText.Image?, maxPixelSize: CGFloat = 512, contentMode: ContentMode = .fill,
         @ViewBuilder placeholder: @escaping (_ failed: Bool) -> Placeholder) {
        self.source = source
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: DecodedImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                if image.isAnimated && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        frame(image.frame(at: context.date))
                    }
                } else {
                    frame(image.frames[0])
                }
            } else {
                placeholder(failed)
            }
        }
        .task(id: source) {
            image = nil
            failed = false
            guard let source else { return }

            do {
                image = try await ImageLoader.shared.image(source, maxPixelSize: maxPixelSize)
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    private func frame(_ cgImage: CGImage) -> some View {
        Image(decorative: cgImage, scale: 1)
            .resizable()
            .aspectRatio(contentMode: contentMode)
    }
}

/// All frames of an image (one for stills) and when each one ends.
nonisolated final class DecodedImage: @unchecked Sendable {
    let frames: [CGImage]
    /// Cumulative end time of each frame, in seconds.
    private let ends: [Double]

    init(frames: [CGImage], delays: [Double]) {
        self.frames = frames
        var total = 0.0
        ends = delays.map { total += $0; return total }
    }

    var isAnimated: Bool { frames.count > 1 }

    var cost: Int { frames.reduce(0) { $0 + $1.bytesPerRow * $1.height } }

    func frame(at date: Date) -> CGImage {
        guard isAnimated, let duration = ends.last, duration > 0 else { return frames[0] }
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration)

        // Binary search for the first frame ending after t.
        var low = 0, high = ends.count - 1
        while low < high {
            let mid = (low + high) / 2
            if ends[mid] > t { high = mid } else { low = mid + 1 }
        }
        return frames[low]
    }
}

/// Downloads and decodes images once, sharing in-flight loads between views.
actor ImageLoader {
    static let shared = ImageLoader()

    private struct Key: Hashable {
        /// The URL, or a digest of embedded data.
        let id: String
        let maxPixelSize: Int
    }

    private final class Entry {
        let image: DecodedImage
        init(_ image: DecodedImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Entry>()
    private var loading: [Key: Task<DecodedImage, Error>] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 128 << 20)
        return URLSession(configuration: configuration)
    }()

    init() {
        cache.totalCostLimit = 96 << 20
    }

    func image(_ source: ChatText.Image, maxPixelSize: CGFloat) async throws -> DecodedImage {
        let id = switch source {
        case .url(let url): url.absoluteString
        case .data(let data): "data:" + Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let key = Key(id: id, maxPixelSize: Int(maxPixelSize))
        let cacheKey = "\(key.maxPixelSize)|\(id)" as NSString

        if let entry = cache.object(forKey: cacheKey) { return entry.image }
        if let task = loading[key] { return try await task.value }

        let session = session
        let task = Task {
            let data: Data
            switch source {
            case .data(let embedded):
                data = embedded
            case .url(let url):
                let (downloaded, response) = try await session.data(from: url)
                if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                    throw URLError(.badServerResponse)
                }
                data = downloaded
            }
            return try await Self.decode(data, maxPixelSize: maxPixelSize)
        }

        loading[key] = task
        defer { loading[key] = nil }

        let image = try await task.value
        cache.setObject(Entry(image), forKey: cacheKey, cost: image.cost)
        return image
    }

    /// Decodes every frame, downsampled; very large animations are decoded smaller to keep memory in check.
    @concurrent
    private static func decode(_ data: Data, maxPixelSize: CGFloat) async throws -> DecodedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw URLError(.cannotDecodeContentData) }

        let count = min(CGImageSourceGetCount(source), 500)
        guard count > 0 else { throw URLError(.cannotDecodeContentData) }

        var maxPixel = maxPixelSize
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 {
            // At most ~40 MB of frames.
            let scale = min(1, maxPixel / max(width, height))
            let bytes = width * scale * height * scale * 4 * CGFloat(count)
            let budget = CGFloat(40 << 20)
            if bytes > budget { maxPixel *= (budget / bytes).squareRoot() }
            maxPixel = min(maxPixel, max(width, height))
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maxPixel),
        ]

        var frames: [CGImage] = []
        var delays: [Double] = []

        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
            frames.append(frame)
            delays.append(delay(source, index))
        }

        guard !frames.isEmpty else { throw URLError(.cannotDecodeContentData) }
        return DecodedImage(frames: frames, delays: delays)
    }

    /// A frame's delay; very short delays are shown at 0.1 s, as browsers do.
    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }

        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]

        for (dictionary, unclamped, clamped) in containers {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            let delay = (values[unclamped] as? Double) ?? (values[clamped] as? Double) ?? 0.1
            return delay < 0.011 ? 0.1 : delay
        }
        return 0.1
    }
}
