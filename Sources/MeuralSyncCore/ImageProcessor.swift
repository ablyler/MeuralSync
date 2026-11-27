import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageProcessingError: Error, LocalizedError, Sendable {
    case unreadableImage(URL)
    case contextCreationFailed
    case imageEncodingFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let url):
            return "Unable to read image at \(url.path)"
        case .contextCreationFailed:
            return "Failed to create Core Graphics context"
        case .imageEncodingFailed(let url):
            return "Failed to encode JPEG to \(url.path)"
        }
    }
}

public struct FontMetrics: Sendable, Equatable {
    public let textWidth: Double
    public let ascender: Double
    public let descender: Double
    public let textHeight: Double

    public init(textWidth: Double, ascender: Double, descender: Double, textHeight: Double) {
        self.textWidth = textWidth
        self.ascender = ascender
        self.descender = descender
        self.textHeight = textHeight
    }
}

public protocol TextMeasuring: Sendable {
    func measure(_ text: String, fontSize: Double) -> FontMetrics
}

public struct CoreTextMeasurer: TextMeasuring {
    public let fontName: String

    public init(fontName: String = ImageProcessor.resolvePreferredFontName()) {
        self.fontName = fontName
    }

    public func makeFont(size: Double) -> CTFont {
        CTFontCreateWithName(fontName as CFString, CGFloat(size), nil)
    }

    public func measure(_ text: String, fontSize: Double) -> FontMetrics {
        let font = makeFont(size: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let fontAscent = max(ascent, CTFontGetAscent(font))
        let fontDescent = max(descent, CTFontGetDescent(font))
        return FontMetrics(
            textWidth: Double(width),
            ascender: Double(fontAscent),
            descender: -Double(fontDescent),
            textHeight: Double(fontAscent + fontDescent)
        )
    }
}

public struct CaptionRow: Sendable, Equatable {
    public let text: String
    public let fontSize: Int
    /// Baseline Y coordinate measured from the TOP of the image (top-left coordinate origin).
    public let baselineY: Int

    public init(text: String, fontSize: Int, baselineY: Int) {
        self.text = text
        self.fontSize = fontSize
        self.baselineY = baselineY
    }
}

public struct CaptionBounds: Sendable, Equatable {
    public let left: Int
    public let top: Int
    public let right: Int
    public let bottom: Int

    public init(left: Int, top: Int, right: Int, bottom: Int) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
}

public struct CaptionLayout: Sendable, Equatable {
    public let rows: [CaptionRow]
    public let bounds: CaptionBounds
    public let textLeft: Int
    public let iconName: String?
    public let iconSize: Int
    public let gap: Int

    public init(
        rows: [CaptionRow],
        bounds: CaptionBounds,
        textLeft: Int,
        iconName: String?,
        iconSize: Int,
        gap: Int
    ) {
        self.rows = rows
        self.bounds = bounds
        self.textLeft = textLeft
        self.iconName = iconName
        self.iconSize = iconSize
        self.gap = gap
    }
}

public enum ImageProcessor {
    public static let meuralWidth = 1080
    public static let meuralHeight = 1920

    private static let cachedPreferredFontName: String = {
        let candidates = ["Lato-Regular", "Lato", "HelveticaNeue", "Helvetica", "ArialMT"]
        let available = (CTFontManagerCopyAvailablePostScriptNames() as? [String]).map(Set.init) ?? []
        for name in candidates where available.contains(name) {
            return name
        }
        return "HelveticaNeue"
    }()

    private static func formatCaptionDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    public static func resolvePreferredFontName() -> String {
        cachedPreferredFontName
    }

    // MARK: - Loading & Saving

    /// Loads an image and applies EXIF orientation so the returned CGImage is always upright.
    public static func loadOrientedImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageProcessingError.unreadableImage(url)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up

        guard let rawImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageProcessingError.unreadableImage(url)
        }
        if orientation == .up {
            return rawImage
        }
        return try applyOrientation(rawImage, orientation: orientation)
    }

    private static func applyOrientation(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let rotated = orientation == .left || orientation == .leftMirrored
            || orientation == .right || orientation == .rightMirrored
        let outW = rotated ? Int(h) : Int(w)
        let outH = rotated ? Int(w) : Int(h)

        guard let ctx = makeSRGBContext(width: outW, height: outH) else {
            throw ImageProcessingError.contextCreationFailed
        }

        var transform = CGAffineTransform.identity
        switch orientation {
        case .down, .downMirrored:
            transform = transform.translatedBy(x: CGFloat(outW), y: CGFloat(outH)).rotated(by: .pi)
        case .left, .leftMirrored:
            transform = transform.translatedBy(x: CGFloat(outW), y: 0).rotated(by: .pi / 2)
        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: CGFloat(outH)).rotated(by: -.pi / 2)
        default:
            break
        }

        switch orientation {
        case .upMirrored, .downMirrored:
            transform = transform.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored:
            transform = transform.translatedBy(x: h, y: 0).scaledBy(x: -1, y: 1)
        default:
            break
        }

        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = ctx.makeImage() else {
            throw ImageProcessingError.contextCreationFailed
        }
        return result
    }

    public static func saveJPEG(_ image: CGImage, to url: URL, quality: Double = 0.92) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageProcessingError.imageEncodingFailed(url)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageProcessingError.imageEncodingFailed(url)
        }
    }

    private static func makeSRGBContext(width: Int, height: Int) -> CGContext? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
        ctx?.interpolationQuality = .high
        return ctx
    }

    // MARK: - Core Operations

    /// Resize an image to fit Meural display dimensions (landscape -> 1080px wide, portrait -> 1920px tall).
    public static func resize(_ image: CGImage) throws -> CGImage {
        let targetWidth: Int
        let targetHeight: Int
        if image.width > image.height {
            targetWidth = meuralWidth
            targetHeight = max(1, Int(Double(image.height) * (Double(targetWidth) / Double(image.width))))
        } else {
            targetHeight = meuralHeight
            targetWidth = max(1, Int(Double(image.width) * (Double(targetHeight) / Double(image.height))))
        }

        guard let ctx = makeSRGBContext(width: targetWidth, height: targetHeight) else {
            throw ImageProcessingError.contextCreationFailed
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let resized = ctx.makeImage() else {
            throw ImageProcessingError.contextCreationFailed
        }
        return resized
    }

    /// Extend an image to fill a 1080x1920 black canvas, centered.
    public static func fillFullsize(_ image: CGImage) throws -> CGImage {
        guard let ctx = makeSRGBContext(width: meuralWidth, height: meuralHeight) else {
            throw ImageProcessingError.contextCreationFailed
        }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: meuralWidth, height: meuralHeight))

        let originX = (meuralWidth - image.width) / 2
        let originY = (meuralHeight - image.height) / 2
        ctx.draw(image, in: CGRect(x: originX, y: originY, width: image.width, height: image.height))
        guard let result = ctx.makeImage() else {
            throw ImageProcessingError.contextCreationFailed
        }
        return result
    }

    /// Combine two horizontal images vertically on a 1080x1920 black canvas with equal non-negative spacing.
    public static func combine(_ imageA: CGImage, _ imageB: CGImage) throws -> CGImage {
        var widthA = meuralWidth
        var heightA = max(1, Int(Double(imageA.height) * (Double(meuralWidth) / Double(imageA.width))))
        var widthB = meuralWidth
        var heightB = max(1, Int(Double(imageB.height) * (Double(meuralWidth) / Double(imageB.width))))

        // If two near-square images exceed the canvas height, scale both proportionally so they never overlap.
        let minSpacing = 12
        let maxCombinedHeight = meuralHeight - 3 * minSpacing
        if heightA + heightB > maxCombinedHeight {
            let scale = Double(maxCombinedHeight) / Double(heightA + heightB)
            widthA = max(1, Int((Double(widthA) * scale).rounded()))
            heightA = max(1, Int((Double(heightA) * scale).rounded()))
            widthB = max(1, Int((Double(widthB) * scale).rounded()))
            heightB = max(1, Int((Double(heightB) * scale).rounded()))
        }

        let spacing = max(0, (meuralHeight - heightA - heightB) / 3)

        guard let ctx = makeSRGBContext(width: meuralWidth, height: meuralHeight) else {
            throw ImageProcessingError.contextCreationFailed
        }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: meuralWidth, height: meuralHeight))

        // Core Graphics has bottom-left origin; top-left y=spacing maps to cgY = meuralHeight - y - height.
        let topA = spacing
        let topB = spacing + heightA + spacing
        let cgYA = meuralHeight - topA - heightA
        let cgYB = meuralHeight - topB - heightB
        let originXA = (meuralWidth - widthA) / 2
        let originXB = (meuralWidth - widthB) / 2

        ctx.draw(imageA, in: CGRect(x: originXA, y: cgYA, width: widthA, height: heightA))
        ctx.draw(imageB, in: CGRect(x: originXB, y: cgYB, width: widthB, height: heightB))

        guard let result = ctx.makeImage() else {
            throw ImageProcessingError.contextCreationFailed
        }
        return result
    }

    // MARK: - Caption Layout & Truncation

    public static func truncateTextToFit(
        _ text: String,
        maxWidth: Double,
        fontSize: Double,
        measurer: any TextMeasuring
    ) -> String {
        let normalized = Captions.normalizeWhitespace(text)
        guard maxWidth > 0 else { return "" }
        if measurer.measure(normalized, fontSize: fontSize).textWidth <= maxWidth {
            return normalized
        }
        if measurer.measure("...", fontSize: fontSize).textWidth > maxWidth {
            return ""
        }

        let chars = Array(normalized)
        var low = 0
        var high = chars.count
        while low < high {
            let mid = (low + high + 1) / 2
            let prefix = String(chars[0..<mid]).trimmingTrailingWhitespace()
            let candidate = prefix + "..."
            if measurer.measure(candidate, fontSize: fontSize).textWidth <= maxWidth {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return String(chars[0..<low]).trimmingTrailingWhitespace() + "..."
    }

    public static func fitCaptionNames(
        persons: [String],
        includeList: [String]?,
        maxWidth: Double,
        fontSize: Double,
        personAliases: [String: String] = Captions.defaultPersonAliases,
        measurer: any TextMeasuring
    ) -> String {
        let names = Captions.displayPersonNames(persons, includeList: includeList, personAliases: personAliases)
        guard !names.isEmpty else { return "" }

        for count in stride(from: names.count, through: 1, by: -1) {
            let remaining = names.count - count
            let suffix: String
            if remaining == 0 {
                suffix = ""
            } else if remaining == 1 {
                suffix = " +1 other"
            } else {
                suffix = " +\(remaining) others"
            }
            let text = names.prefix(count).joined(separator: ", ") + suffix
            if measurer.measure(text, fontSize: fontSize).textWidth <= maxWidth {
                return text
            }
        }

        let suffix: String
        if names.count > 2 {
            suffix = " +\(names.count - 1) others"
        } else if names.count == 2 {
            suffix = " +1 other"
        } else {
            suffix = ""
        }
        let available = maxWidth - measurer.measure(suffix, fontSize: fontSize).textWidth
        let first = truncateTextToFit(names[0], maxWidth: available, fontSize: fontSize, measurer: measurer)
        if !first.isEmpty {
            return first + suffix
        }
        return truncateTextToFit(suffix.trimmingCharacters(in: .whitespaces), maxWidth: maxWidth, fontSize: fontSize, measurer: measurer)
    }

    public static func computeCaptionLayout(
        imageWidth: Int,
        imageHeight: Int,
        photo: PhotoMetadata,
        includeList: [String]? = nil,
        locationAliases: [String: String]? = nil,
        personAliases: [String: String] = Captions.defaultPersonAliases,
        measurer: any TextMeasuring = CoreTextMeasurer()
    ) -> CaptionLayout {
        let scale = min(1.0, Double(imageWidth) / 1080.0, Double(imageHeight) / 360.0)
        let margin = max(1, Int((16.0 * scale).rounded()))
        let padding = max(1, Int((12.0 * scale).rounded()))
        let gap = max(1, Int((8.0 * scale).rounded()))
        let maxWidth = Double(imageWidth - 2 * (margin + padding))
        let primarySize = max(1, Int((36.0 * scale).rounded()))
        let secondarySize = max(1, Int((24.0 * scale).rounded()))

        let names = fitCaptionNames(
            persons: photo.persons,
            includeList: includeList,
            maxWidth: maxWidth,
            fontSize: Double(primarySize),
            personAliases: personAliases,
            measurer: measurer
        )

        var rawRows: [(String, Int)] = []
        if !names.isEmpty {
            rawRows.append((names, primarySize))
        }

        let formattedLocation = Captions.formatLocation(
            photo.placeName,
            aliases: locationAliases,
            areasOfInterest: photo.areasOfInterest
        )
        var metadata = formatCaptionDate(photo.date)
        if !formattedLocation.label.isEmpty {
            metadata += "  ·  \(formattedLocation.label)"
        }

        let iconSize = formattedLocation.iconName != nil ? Int((Double(secondarySize) * 1.5).rounded()) : 0
        let iconSpace = formattedLocation.iconName != nil ? iconSize + gap : 0
        let fittedMetadata = truncateTextToFit(
            metadata,
            maxWidth: maxWidth - Double(iconSpace),
            fontSize: Double(secondarySize),
            measurer: measurer
        )
        rawRows.append((fittedMetadata, secondarySize))

        var top = margin + padding
        var layoutRows: [CaptionRow] = []
        var panelWidth = 0

        for (index, (text, size)) in rawRows.enumerated() {
            if text.isEmpty { continue }
            let metrics = measurer.measure(text, fontSize: Double(size))
            var ascent = Int(ceil(metrics.ascender))
            let descent = Int(ceil(abs(metrics.descender)))
            let isMetadata = index == rawRows.count - 1
            if isMetadata {
                ascent = max(ascent, iconSize)
            }
            layoutRows.append(CaptionRow(text: text, fontSize: size, baselineY: top + ascent))
            panelWidth = max(
                panelWidth,
                Int(ceil(metrics.textWidth)) + (isMetadata ? iconSpace : 0)
            )
            top += max(ascent + descent, Int(ceil(metrics.textHeight))) + gap
        }

        let bounds = CaptionBounds(
            left: margin,
            top: margin,
            right: margin + panelWidth + 2 * padding,
            bottom: top - gap + padding
        )

        return CaptionLayout(
            rows: layoutRows,
            bounds: bounds,
            textLeft: margin + padding,
            iconName: formattedLocation.iconName,
            iconSize: iconSize,
            gap: gap
        )
    }

    /// Renders the translucent caption panel, optional Disney park/ride icon, and text onto the image.
    public static func addCaption(
        to image: CGImage,
        photo: PhotoMetadata,
        includeList: [String]? = nil,
        locationAliases: [String: String]? = nil,
        personAliases: [String: String] = Captions.defaultPersonAliases,
        fontName: String = resolvePreferredFontName()
    ) throws -> (image: CGImage, layout: CaptionLayout) {
        let width = image.width
        let height = image.height
        let measurer = CoreTextMeasurer(fontName: fontName)
        let layout = computeCaptionLayout(
            imageWidth: width,
            imageHeight: height,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases,
            measurer: measurer
        )

        guard let ctx = makeSRGBContext(width: width, height: height) else {
            throw ImageProcessingError.contextCreationFailed
        }

        // Draw base image
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Draw translucent black panel (convert top-left bounds to CG bottom-left coordinates)
        let panelWidth = layout.bounds.right - layout.bounds.left
        let panelHeight = layout.bounds.bottom - layout.bounds.top
        let panelCGY = height - layout.bounds.bottom
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.65))
        ctx.fill(CGRect(x: layout.bounds.left, y: panelCGY, width: panelWidth, height: panelHeight))

        // Draw rows and optional park/attraction icon
        for (index, row) in layout.rows.enumerated() {
            var textLeft = layout.textLeft
            let isMetadata = index == layout.rows.count - 1

            if isMetadata,
               let iconName = layout.iconName,
               let iconURL = Captions.iconURL(for: iconName),
               let iconImage = try? loadOrientedImage(from: iconURL)
            {
                let boxSize = CGFloat(layout.iconSize)
                let scaleFactor = min(boxSize / CGFloat(iconImage.width), boxSize / CGFloat(iconImage.height))
                let drawW = CGFloat(iconImage.width) * scaleFactor
                let drawH = CGFloat(iconImage.height) * scaleFactor
                let drawX = CGFloat(layout.textLeft) + (boxSize - drawW) / 2.0
                let topInTopLeft = CGFloat(row.baselineY - layout.iconSize) + (boxSize - drawH) / 2.0
                let cgY = CGFloat(height) - topInTopLeft - drawH
                ctx.draw(iconImage, in: CGRect(x: drawX, y: cgY, width: drawW, height: drawH))
                textLeft += layout.iconSize + layout.gap
            }

            let font = measurer.makeFont(size: Double(row.fontSize))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            ]
            let attrString = NSAttributedString(string: row.text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrString)
            let baselineCGY = CGFloat(height - row.baselineY)

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: CGFloat(textLeft), y: baselineCGY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        guard let result = ctx.makeImage() else {
            throw ImageProcessingError.contextCreationFailed
        }
        return (result, layout)
    }

    // MARK: - File-Based Convenience Pipeline

    public static func processPortraitImage(
        _ loaded: CGImage,
        photo: PhotoMetadata,
        includeList: [String]?,
        locationAliases: [String: String]?,
        personAliases: [String: String] = Captions.defaultPersonAliases,
        outputURL: URL
    ) throws -> CaptionLayout {
        let resized = try resize(loaded)
        let filled = try fillFullsize(resized)
        let (captioned, layout) = try addCaption(
            to: filled,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases
        )
        try saveJPEG(captioned, to: outputURL)
        return layout
    }

    public static func processPortraitFile(
        sourceURL: URL,
        photo: PhotoMetadata,
        includeList: [String]?,
        locationAliases: [String: String]?,
        personAliases: [String: String] = Captions.defaultPersonAliases,
        outputURL: URL
    ) throws -> CaptionLayout {
        let loaded = try loadOrientedImage(from: sourceURL)
        return try processPortraitImage(
            loaded,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases,
            outputURL: outputURL
        )
    }

    public static func processLandscapeImage(
        _ loaded: CGImage,
        photo: PhotoMetadata,
        includeList: [String]?,
        locationAliases: [String: String]?,
        personAliases: [String: String] = Captions.defaultPersonAliases
    ) throws -> (image: CGImage, layout: CaptionLayout) {
        let resized = try resize(loaded)
        return try addCaption(
            to: resized,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases
        )
    }

    public static func processLandscapeImage(
        sourceURL: URL,
        photo: PhotoMetadata,
        includeList: [String]?,
        locationAliases: [String: String]?,
        personAliases: [String: String] = Captions.defaultPersonAliases
    ) throws -> (image: CGImage, layout: CaptionLayout) {
        let loaded = try loadOrientedImage(from: sourceURL)
        return try processLandscapeImage(
            loaded,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases
        )
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return result
    }
}
