import AppKit
import CoreGraphics
import CoreImage
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

    // CIContext is documented thread-safe; nonisolated(unsafe) is needed for Swift 6.0/6.1 SDKs where CIContext lacks Sendable.
    nonisolated(unsafe) private static let ciContext = CIContext()

    private static let cachedPreferredFontName: String = {
        let candidates = ["Lato-Regular", "Lato", "HelveticaNeue", "Helvetica", "ArialMT"]
        let available = (CTFontManagerCopyAvailablePostScriptNames() as? [String]).map(Set.init) ?? []
        for name in candidates where available.contains(name) {
            return name
        }
        return "HelveticaNeue"
    }()

    private static let cachedPreferredMediumFontName: String = {
        let candidates = ["Lato-Bold", "Lato-Semibold", "Lato-Medium", "HelveticaNeue-Medium", "Helvetica-Bold", "Arial-BoldMT"]
        let available = (CTFontManagerCopyAvailablePostScriptNames() as? [String]).map(Set.init) ?? []
        for name in candidates where available.contains(name) {
            return name
        }
        return cachedPreferredFontName
    }()

    public static func resolvePreferredFontName() -> String {
        cachedPreferredFontName
    }

    public static func resolvePreferredMediumFontName() -> String {
        cachedPreferredMediumFontName
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

    /// Resize an image to fit Meural display dimensions for the given frame orientation.
    /// - Portrait frame (`1080×1920`): landscape -> 1080px wide, portrait/square -> 1920px tall.
    /// - Landscape frame (`1920×1080`): portrait -> 1080px tall, landscape/square -> 1920px wide.
    public static func resize(_ image: CGImage, orientation: CanvasOrientation = .portrait) throws -> CGImage {
        let targetWidth: Int
        let targetHeight: Int
        switch orientation {
        case .portrait:
            if image.width > image.height {
                targetWidth = orientation.canvasWidth
                targetHeight = max(1, Int(Double(image.height) * (Double(targetWidth) / Double(image.width))))
            } else {
                targetHeight = orientation.canvasHeight
                targetWidth = max(1, Int(Double(image.width) * (Double(targetHeight) / Double(image.height))))
            }
        case .landscape:
            if image.height > image.width {
                targetHeight = orientation.canvasHeight
                targetWidth = max(1, Int(Double(image.width) * (Double(targetHeight) / Double(image.height))))
            } else {
                targetWidth = orientation.canvasWidth
                targetHeight = max(1, Int(Double(image.height) * (Double(targetWidth) / Double(image.width))))
            }
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

    /// Extend an image to fill a Meural black canvas (`1080×1920` portrait or `1920×1080` landscape), centered.
    public static func fillFullsize(_ image: CGImage, orientation: CanvasOrientation = .portrait) throws -> CGImage {
        let canvasW = orientation.canvasWidth
        let canvasH = orientation.canvasHeight
        guard let ctx = makeSRGBContext(width: canvasW, height: canvasH) else {
            throw ImageProcessingError.contextCreationFailed
        }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        let originX = (canvasW - image.width) / 2
        let originY = (canvasH - image.height) / 2
        ctx.draw(image, in: CGRect(x: originX, y: originY, width: image.width, height: image.height))
        guard let result = ctx.makeImage() else {
            throw ImageProcessingError.contextCreationFailed
        }
        return result
    }

    /// Combine two opposite-orientation images on a Meural black canvas with equal non-negative spacing:
    /// - Portrait frame (`1080×1920`): stacks two landscape images vertically.
    /// - Landscape frame (`1920×1080`): places two portrait images side-by-side horizontally.
    public static func combine(
        _ imageA: CGImage,
        _ imageB: CGImage,
        orientation: CanvasOrientation = .portrait
    ) throws -> CGImage {
        let canvasW = orientation.canvasWidth
        let canvasH = orientation.canvasHeight
        let minSpacing = 12

        guard let ctx = makeSRGBContext(width: canvasW, height: canvasH) else {
            throw ImageProcessingError.contextCreationFailed
        }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        switch orientation {
        case .portrait:
            var widthA = canvasW
            var heightA = max(1, Int(Double(imageA.height) * (Double(canvasW) / Double(imageA.width))))
            var widthB = canvasW
            var heightB = max(1, Int(Double(imageB.height) * (Double(canvasW) / Double(imageB.width))))

            let maxCombinedHeight = canvasH - 3 * minSpacing
            if heightA + heightB > maxCombinedHeight {
                let scale = Double(maxCombinedHeight) / Double(heightA + heightB)
                widthA = max(1, Int((Double(widthA) * scale).rounded()))
                heightA = max(1, Int((Double(heightA) * scale).rounded()))
                widthB = max(1, Int((Double(widthB) * scale).rounded()))
                heightB = max(1, Int((Double(heightB) * scale).rounded()))
            }

            let spacing = max(0, (canvasH - heightA - heightB) / 3)
            let topA = spacing
            let topB = spacing + heightA + spacing
            let cgYA = canvasH - topA - heightA
            let cgYB = canvasH - topB - heightB
            let originXA = (canvasW - widthA) / 2
            let originXB = (canvasW - widthB) / 2

            ctx.draw(imageA, in: CGRect(x: originXA, y: cgYA, width: widthA, height: heightA))
            ctx.draw(imageB, in: CGRect(x: originXB, y: cgYB, width: widthB, height: heightB))

        case .landscape:
            var heightA = canvasH
            var widthA = max(1, Int(Double(imageA.width) * (Double(canvasH) / Double(imageA.height))))
            var heightB = canvasH
            var widthB = max(1, Int(Double(imageB.width) * (Double(canvasH) / Double(imageB.height))))

            let maxCombinedWidth = canvasW - 3 * minSpacing
            if widthA + widthB > maxCombinedWidth {
                let scale = Double(maxCombinedWidth) / Double(widthA + widthB)
                widthA = max(1, Int((Double(widthA) * scale).rounded()))
                heightA = max(1, Int((Double(heightA) * scale).rounded()))
                widthB = max(1, Int((Double(widthB) * scale).rounded()))
                heightB = max(1, Int((Double(heightB) * scale).rounded()))
            }

            let spacing = max(0, (canvasW - widthA - widthB) / 3)
            let originXA = spacing
            let originXB = spacing + widthA + spacing
            let cgYA = (canvasH - heightA) / 2
            let cgYB = (canvasH - heightB) / 2

            ctx.draw(imageA, in: CGRect(x: originXA, y: cgYA, width: widthA, height: heightA))
            ctx.draw(imageB, in: CGRect(x: originXB, y: cgYB, width: widthB, height: heightB))
        }

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
        dateFormat: CaptionDateFormat = .medium,
        measurer: any TextMeasuring = CoreTextMeasurer()
    ) -> CaptionLayout {
        let scale = min(1.0, Double(imageWidth) / 1080.0, Double(imageHeight) / 360.0)
        let margin = max(1, Int((20.0 * scale).rounded()))
        let padX = max(1, Int((20.0 * scale).rounded()))
        let padYTop = max(1, Int((9.0 * scale).rounded()))
        let padYBottom = max(1, Int((12.0 * scale).rounded()))
        let rowGap = max(1, Int((7.0 * scale).rounded()))
        let primarySize = max(1, Int((35.0 * scale).rounded()))
        let secondarySize = max(1, Int((23.0 * scale).rounded()))

        let formattedLocation = Captions.formatLocation(
            photo.placeName,
            aliases: locationAliases,
            areasOfInterest: photo.areasOfInterest
        )
        let hasIcon = formattedLocation.iconName != nil
        let hasNames = !Captions.displayPersonNames(
            photo.persons,
            includeList: includeList,
            personAliases: personAliases
        ).isEmpty

        let iconSize = hasIcon ? max(1, Int(((hasNames ? 44.0 : 28.0) * scale).rounded())) : 0
        let iconGap = hasIcon ? max(1, Int(((hasNames ? 14.0 : 9.0) * scale).rounded())) : 0
        let iconSpace = hasIcon ? iconSize + iconGap : 0
        let textMaxWidth = Double(imageWidth - 2 * (margin + padX) - iconSpace)

        let names = fitCaptionNames(
            persons: photo.persons,
            includeList: includeList,
            maxWidth: textMaxWidth,
            fontSize: Double(primarySize),
            personAliases: personAliases,
            measurer: measurer
        )

        var rawRows: [(String, Int)] = []
        if !names.isEmpty {
            rawRows.append((names, primarySize))
        }

        var metadata = dateFormat.format(photo.date)
        if !formattedLocation.label.isEmpty {
            metadata += " · \(formattedLocation.label)"
        }

        let fittedMetadata = truncateTextToFit(
            metadata,
            maxWidth: textMaxWidth,
            fontSize: Double(secondarySize),
            measurer: measurer
        )
        rawRows.append((fittedMetadata, secondarySize))

        var top = margin + padYTop
        var layoutRows: [CaptionRow] = []
        var textPanelWidth = 0

        for (text, size) in rawRows {
            if text.isEmpty { continue }
            let metrics = measurer.measure(text, fontSize: Double(size))
            let ascent = Int(ceil(metrics.ascender))
            let descent = Int(ceil(abs(metrics.descender)))
            layoutRows.append(CaptionRow(text: text, fontSize: size, baselineY: top + ascent))
            textPanelWidth = max(textPanelWidth, Int(ceil(metrics.textWidth)))
            top += max(ascent + descent, Int(ceil(metrics.textHeight))) + rowGap
        }

        let textBottom = top - rowGap + padYBottom
        let minIconBottom = hasIcon ? (margin + padYTop + iconSize + padYBottom) : textBottom
        let bounds = CaptionBounds(
            left: margin,
            top: margin,
            right: margin + 2 * padX + iconSpace + textPanelWidth,
            bottom: max(textBottom, minIconBottom)
        )

        return CaptionLayout(
            rows: layoutRows,
            bounds: bounds,
            textLeft: margin + padX + iconSpace,
            iconName: formattedLocation.iconName,
            iconSize: iconSize,
            gap: iconGap
        )
    }

    /// Renders the frosted-glass caption pill, optional two-row left park/ride icon, and text onto the image.
    public static func addCaption(
        to image: CGImage,
        photo: PhotoMetadata,
        includeList: [String]? = nil,
        locationAliases: [String: String]? = nil,
        personAliases: [String: String] = Captions.defaultPersonAliases,
        dateFormat: CaptionDateFormat = .medium,
        fontName: String = resolvePreferredFontName(),
        primaryFontName: String = resolvePreferredMediumFontName()
    ) throws -> (image: CGImage, layout: CaptionLayout) {
        let width = image.width
        let height = image.height
        let scale = min(1.0, Double(width) / 1080.0, Double(height) / 360.0)
        let primaryMeasurer = CoreTextMeasurer(fontName: primaryFontName)
        let secondaryMeasurer = CoreTextMeasurer(fontName: fontName)
        let layout = computeCaptionLayout(
            imageWidth: width,
            imageHeight: height,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases,
            dateFormat: dateFormat,
            measurer: secondaryMeasurer
        )

        guard let ctx = makeSRGBContext(width: width, height: height) else {
            throw ImageProcessingError.contextCreationFailed
        }

        // Draw base image
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Draw frosted-glass rounded pill (convert top-left bounds to CG bottom-left coordinates)
        let panelWidth = CGFloat(layout.bounds.right - layout.bounds.left)
        let panelHeight = CGFloat(layout.bounds.bottom - layout.bounds.top)
        let panelCGY = CGFloat(height - layout.bounds.bottom)
        let panelRect = CGRect(x: CGFloat(layout.bounds.left), y: panelCGY, width: panelWidth, height: panelHeight)
        let cornerRadius = min(panelHeight / 2.0, max(4.0, CGFloat(15.0 * scale)))
        let panelPath = CGPath(roundedRect: panelRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        let blurSigma = max(2.0, 14.0 * scale)
        let blurredCI = CIImage(cgImage: image)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: blurSigma)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        ctx.saveGState()
        ctx.addPath(panelPath)
        ctx.clip()
        if let blurredCG = ciContext.createCGImage(blurredCI, from: panelRect) {
            ctx.draw(blurredCG, in: panelRect)
        }
        ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.08, blue: 0.11, alpha: 0.56))
        ctx.fill(panelRect)
        ctx.restoreGState()

        // Subtle light hairline border
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20))
        ctx.setLineWidth(max(1.0, CGFloat(1.25 * scale)))
        ctx.addPath(panelPath)
        ctx.strokePath()
        ctx.restoreGState()

        // Draw optional park/attraction icon vertically centered across the entire pill on the left
        if let iconName = layout.iconName,
           layout.iconSize > 0,
           let iconURL = Captions.iconURL(for: iconName),
           let iconImage = try? loadOrientedImage(from: iconURL)
        {
            let boxSize = CGFloat(layout.iconSize)
            let scaleFactor = min(boxSize / CGFloat(iconImage.width), boxSize / CGFloat(iconImage.height))
            let drawW = CGFloat(iconImage.width) * scaleFactor
            let drawH = CGFloat(iconImage.height) * scaleFactor
            let iconLeft = CGFloat(layout.textLeft - layout.iconSize - layout.gap)
            let drawX = iconLeft + (boxSize - drawW) / 2.0
            let pillCenterYTopLeft = CGFloat(layout.bounds.top + layout.bounds.bottom) / 2.0
            let topInTopLeft = pillCenterYTopLeft - drawH / 2.0
            let cgY = CGFloat(height) - topInTopLeft - drawH
            ctx.saveGState()
            ctx.setAlpha(0.92)
            ctx.draw(iconImage, in: CGRect(x: drawX, y: cgY, width: drawW, height: drawH))
            ctx.restoreGState()
        }

        // Draw left-aligned text rows
        for (index, row) in layout.rows.enumerated() {
            let isPrimary = layout.rows.count > 1 && index == 0
            let font = isPrimary
                ? primaryMeasurer.makeFont(size: Double(row.fontSize))
                : secondaryMeasurer.makeFont(size: Double(row.fontSize))
            let textColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: isPrimary ? 1.0 : 0.85)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
            ]
            let attrString = NSAttributedString(string: row.text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrString)
            let baselineCGY = CGFloat(height - row.baselineY)

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: CGFloat(layout.textLeft), y: baselineCGY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        guard let result = ctx.makeImage() else {
            throw ImageProcessingError.contextCreationFailed
        }
        return (result, layout)
    }

    // MARK: - File-Based Convenience Pipeline

    public static func processFullsizeImage(
        _ loaded: CGImage,
        photo: PhotoMetadata,
        includeList: [String]?,
        locationAliases: [String: String]?,
        personAliases: [String: String] = Captions.defaultPersonAliases,
        dateFormat: CaptionDateFormat = .medium,
        orientation: CanvasOrientation = .portrait,
        outputURL: URL
    ) throws -> CaptionLayout {
        let resized = try resize(loaded, orientation: orientation)
        let filled = try fillFullsize(resized, orientation: orientation)
        let (captioned, layout) = try addCaption(
            to: filled,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases,
            dateFormat: dateFormat
        )
        try saveJPEG(captioned, to: outputURL)
        return layout
    }

    public static func processPairedImage(
        _ loaded: CGImage,
        photo: PhotoMetadata,
        includeList: [String]?,
        locationAliases: [String: String]?,
        personAliases: [String: String] = Captions.defaultPersonAliases,
        dateFormat: CaptionDateFormat = .medium,
        orientation: CanvasOrientation = .portrait
    ) throws -> (image: CGImage, layout: CaptionLayout) {
        let resized = try resize(loaded, orientation: orientation)
        return try addCaption(
            to: resized,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases,
            dateFormat: dateFormat
        )
    }

    public static func processPortraitImage(
        _ loaded: CGImage,
        photo: PhotoMetadata,
        includeList: [String]?,
        locationAliases: [String: String]?,
        personAliases: [String: String] = Captions.defaultPersonAliases,
        outputURL: URL
    ) throws -> CaptionLayout {
        try processFullsizeImage(
            loaded,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases,
            orientation: .portrait,
            outputURL: outputURL
        )
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
        return try processFullsizeImage(
            loaded,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases,
            orientation: .portrait,
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
        try processPairedImage(
            loaded,
            photo: photo,
            includeList: includeList,
            locationAliases: locationAliases,
            personAliases: personAliases,
            orientation: .portrait
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
