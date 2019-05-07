// The MIT License (MIT)
//
// Copyright (c) 2015-2019 Alexander Grebenyuk (github.com/kean).

import Foundation

/// Performs image processing.
public protocol ImageProcessing: Equatable {
    /// Returns processed image.
    func process(image: Image, context: ImageProcessingContext) -> Image?
}

/// Image processing context used when selecting which processor to use.
public struct ImageProcessingContext {
    public let request: ImageRequest
    public let isFinal: Bool
    public let scanNumber: Int? // need a more general purpose way to implement this
}

/// Composes multiple processors.
internal struct ImageProcessorComposition: ImageProcessing {
    private let processors: [AnyImageProcessor]

    /// Composes multiple processors.
    public init(_ processors: [AnyImageProcessor]) {
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

    /// Returns true if the underlying processors are pairwise-equivalent.
    public static func == (lhs: ImageProcessorComposition, rhs: ImageProcessorComposition) -> Bool {
        return lhs.processors == rhs.processors
    }
}

/// Type-erased image processor.
public struct AnyImageProcessor: ImageProcessing {
    private let _process: (Image, ImageProcessingContext) -> Image?
    private let _processor: Any
    private let _equals: (AnyImageProcessor) -> Bool

    public init<P: ImageProcessing>(_ processor: P) {
        self._process = { processor.process(image: $0, context: $1) }
        self._processor = processor
        self._equals = { ($0._processor as? P) == processor }
    }

    public func process(image: Image, context: ImageProcessingContext) -> Image? {
        return self._process(image, context)
    }

    public static func == (lhs: AnyImageProcessor, rhs: AnyImageProcessor) -> Bool {
        return lhs._equals(rhs)
    }
}

internal struct AnonymousImageProcessor<Key: Hashable>: ImageProcessing {
    private let _key: Key
    private let _closure: (Image) -> Image?

    init(_ key: Key, _ closure: @escaping (Image) -> Image?) {
        self._key = key; self._closure = closure
    }

    func process(image: Image, context: ImageProcessingContext) -> Image? {
        return self._closure(image)
    }

    static func == (lhs: AnonymousImageProcessor, rhs: AnonymousImageProcessor) -> Bool {
        return lhs._key == rhs._key
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

struct ImageDecompressor: ImageProcessing {
    func process(image: Image, context: ImageProcessingContext) -> Image? {
        guard ImageDecompressor.isDecompressionNeeded(for: image) ?? false else {
            // Image doesn't require decompression (was modified by one of the
            // processors). This scenario can only be possible if the user
            // provided the processor(s) by the processor decided not to do
            // anything with the given image (e.g. the scaling processor might
            // decide no to change the image size). In this case decompression is
            // still needed.
            return image
        }
        let output = decompress(image)
        ImageDecompressor.setDecompressionNeeded(false, for: output)
        return output
    }

    /// Returns true if both have the same `targetSize` and `contentMode`.
    public static func == (lhs: ImageDecompressor, rhs: ImageDecompressor) -> Bool {
        return true
    }

    // MARK: Managing decompression state

    static var isDecompressionNeededAK = "ImageDecompressor.isDecompressionNeeded.AssociatedKey"

    static func setDecompressionNeeded(_ isDecompressionNeeded: Bool, for image: Image) {
        objc_setAssociatedObject(image, &isDecompressionNeededAK, isDecompressionNeeded, .OBJC_ASSOCIATION_RETAIN)
    }

    static func isDecompressionNeeded(for image: Image) -> Bool? {
        return objc_getAssociatedObject(image, &isDecompressionNeededAK) as? Bool
    }
}

/// Scales down the input images. Maintains original aspect ratio.
public struct ImageScalingProcessor: ImageProcessing {

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

    /// Returns true if both have the same `targetSize` and `contentMode`.
    public static func == (lhs: ImageScalingProcessor, rhs: ImageScalingProcessor) -> Bool {
        return lhs.targetSize == rhs.targetSize && lhs.contentMode == rhs.contentMode
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

// TODO: add a separate method to resize the image, the method should do nothing
// if the scale if one
private func decompress(_ image: UIImage, targetSize: CGSize, contentMode: ImageScalingProcessor.ContentMode, upscale: Bool) -> UIImage {
    guard let cgImage = image.cgImage else { return image }
    let bitmapSize = CGSize(width: cgImage.width, height: cgImage.height)
    let scaleHor = targetSize.width / bitmapSize.width
    let scaleVert = targetSize.height / bitmapSize.height
    let scale = contentMode == .aspectFill ? max(scaleHor, scaleVert) : min(scaleHor, scaleVert)
    return decompress(image, scale: CGFloat(upscale ? scale : min(scale, 1)))
}

private func decompress(_ image: UIImage, scale: CGFloat = 1) -> UIImage {
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
