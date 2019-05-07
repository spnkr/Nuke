// The MIT License (MIT)
//
// Copyright (c) 2015-2019 Alexander Grebenyuk (github.com/kean).

import Foundation

/// Performs image processing.
public protocol ImageProcessing {
    /// Returns processed image.
    func process(image: Image, context: ImageProcessingContext) -> Image?

    /// Returns a string which uniquely identifies the processor.
    var identifier: String { get }

    /// Returns a unique processor identifier.
    ///
    /// The default implementation simply returns `var identifier: String` but
    /// can be overridden as a performance optimization - creating and comparing
    /// strings is _expensive_ so you can opt-in to return something which is
    /// fast to create and to compare. See `ImageDecompressor` to example.
    var hashableIdentifier: AnyHashable { get }
}

public extension ImageProcessing {
    var hashableIdentifier: AnyHashable {
        return identifier
    }
}

/// Image processing context used when selecting which processor to use.
public struct ImageProcessingContext {
    public let request: ImageRequest
    public let isFinal: Bool
    public let scanNumber: Int? // need a more general purpose way to implement this
}

/// Composes multiple processors.
struct ImageProcessorComposition: ImageProcessing, Hashable {
    private let processors: [ImageProcessing]

    /// Composes multiple processors.
    public init(_ processors: [ImageProcessing]) {
        self.processors = processors
    }

    /// Processes the given image by applying each processor in an order in
    /// which they were added. If one of the processors fails to produce
    /// an image the processing stops and `nil` is returned.
    func process(image: Image, context: ImageProcessingContext) -> Image? {
        return processors.reduce(image) { image, processor in
            return autoreleasepool {
                image.flatMap { processor.process(image: $0, context: context) }
            }
        }
    }

    var identifier: String {
        return processors.map({ $0.identifier }).joined()
    }

    var hashableIdentifier: AnyHashable {
        return self
    }

    func hash(into hasher: inout Hasher) {
        for processor in processors {
            hasher.combine(processor.hashableIdentifier)
        }
    }

    static func == (lhs: ImageProcessorComposition, rhs: ImageProcessorComposition) -> Bool {
        guard lhs.processors.count == rhs.processors.count else {
            return false
        }
        // Lazily creates `hashableIdentifiers` because for some processors the
        // identifiers might be expensive to compute.
        return zip(lhs.processors, rhs.processors).allSatisfy {
            $0.hashableIdentifier == $1.hashableIdentifier
        }
    }
}

struct AnonymousImageProcessor: ImageProcessing {
    public let identifier: String
    private let closure: (Image) -> Image?

    init(_ identifier: String, _ closure: @escaping (Image) -> Image?) {
        self.identifier = identifier
        self.closure = closure
    }

    func process(image: Image, context: ImageProcessingContext) -> Image? {
        return self.closure(image)
    }
}

extension ImageProcessing {
    func process(image: ImageContainer, request: ImageRequest) -> Image? {
        let context = ImageProcessingContext(request: request, isFinal: image.isFinal, scanNumber: image.scanNumber)
        return process(image: image.image, context: context)
    }
}

#if !os(macOS)
import UIKit

/// Decompresses and (optionally) scales down input images. Maintains
/// original aspect ratio.
///
/// Decompressing compressed image formats (such as JPEG) can significantly
/// improve drawing performance as it allows a bitmap representation to be
/// created in a background rather than on the main thread.
public struct ImageDecompressor: ImageProcessing, Hashable {

    public var identifier: String {
        return "ImageDecompressor\(targetSize)\(contentMode)\(upscale)"
    }

    public var hashableIdentifier: AnyHashable {
        return self
    }

    /// An option for how to resize the image.
    public enum ContentMode {
        /// Scales the image so that it completely fills the target size.
        /// Doesn't clip images.
        case aspectFill

        /// Scales the image so that it fits the target size.
        case aspectFit
    }

    /// Size to pass to disable resizing.
    public static let MaximumSize = CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )

    private let targetSize: CGSize
    private let contentMode: ContentMode
    private let upscale: Bool

    /// Initializes `Decompressor` with the given parameters.
    /// - parameter targetSize: Size in pixels. `MaximumSize` by default.
    /// - parameter contentMode: An option for how to resize the image
    /// to the target size. `.aspectFill` by default.
    public init(targetSize: CGSize = MaximumSize, contentMode: ContentMode = .aspectFill, upscale: Bool = false) {
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.upscale = upscale
    }

    /// Decompresses and scales the image.
    public func process(image: Image, context: ImageProcessingContext) -> Image? {
        return decompress(image, targetSize: targetSize, contentMode: contentMode, upscale: upscale)
    }

    #if !os(watchOS)
    /// Returns target size in pixels for the given view. Takes main screen
    /// scale into the account.
    public static func targetSize(for view: UIView) -> CGSize { // in pixels
        let scale = UIScreen.main.scale
        let size = view.bounds.size
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    #endif
}

extension CGSize: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
    }
}

func decompress(_ image: UIImage, targetSize: CGSize, contentMode: ImageDecompressor.ContentMode, upscale: Bool) -> UIImage {
    guard let cgImage = image.cgImage else { return image }
    let bitmapSize = CGSize(width: cgImage.width, height: cgImage.height)
    let scaleHor = targetSize.width / bitmapSize.width
    let scaleVert = targetSize.height / bitmapSize.height
    let scale = contentMode == .aspectFill ? max(scaleHor, scaleVert) : min(scaleHor, scaleVert)
    return decompress(image, scale: CGFloat(upscale ? scale : min(scale, 1)))
}

func decompress(_ image: UIImage, scale: CGFloat) -> UIImage {
    guard let cgImage = image.cgImage else { return image }

    let size = CGSize(
        width: round(scale * CGFloat(cgImage.width)),
        height: round(scale * CGFloat(cgImage.height))
    )

    // For more info see:
    // - Quartz 2D Programming Guide
    // - https://github.com/kean/Nuke/issues/35
    // - https://github.com/kean/Nuke/issues/57
    let alphaInfo: CGImageAlphaInfo = isOpaque(cgImage) ? .noneSkipLast : .premultipliedLast

    guard let ctx = CGContext(
        data: nil,
        width: Int(size.width), height: Int(size.height),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: alphaInfo.rawValue) else {
            return image
    }
    ctx.draw(cgImage, in: CGRect(origin: CGPoint.zero, size: size))
    guard let decompressed = ctx.makeImage() else { return image }
    return UIImage(cgImage: decompressed, scale: image.scale, orientation: image.imageOrientation)
}

private func isOpaque(_ image: CGImage) -> Bool {
    let alpha = image.alphaInfo
    return alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
}
#endif
