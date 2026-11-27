import CoreGraphics
import Foundation
import Testing
@testable import MeuralSyncCore

private struct MockMeasurer: TextMeasuring {
    func measure(_ text: String, fontSize: Double) -> FontMetrics {
        FontMetrics(
            textWidth: Double(text.count) * fontSize * 0.6,
            ascender: fontSize * 0.9,
            descender: -fontSize * 0.25,
            textHeight: fontSize * 1.15
        )
    }
}

private func makeSolidImage(width: Int, height: Int, r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@Suite("ImageProcessor")
struct ImageProcessorTests {
    @Test("Caption layout stays inside bounds without overlapping rows")
    func captionLayoutBounds() {
        let date = Date(timeIntervalSince1970: 1_602_979_200) // 2020-10-18 UTC
        let photo = PhotoMetadata(
            uuid: "u1",
            date: date,
            width: 1080,
            height: 540,
            persons: [String(repeating: "Alexandra ", count: 12), String(repeating: "Jane ", count: 15)],
            placeName: "Traverse City, Michigan"
        )
        let measurer = MockMeasurer()

        for (w, h) in [(1080, 1920), (1080, 540), (1080, 120), (320, 180)] {
            let layout = ImageProcessor.computeCaptionLayout(
                imageWidth: w,
                imageHeight: h,
                photo: photo,
                measurer: measurer
            )
            #expect(layout.rows.count <= 2)
            #expect(layout.bounds.right < w)
            #expect(layout.bounds.bottom < h)
            var prevBottom = Double(layout.bounds.top)
            for row in layout.rows {
                let m = measurer.measure(row.text, fontSize: Double(row.fontSize))
                #expect(Double(row.baselineY) - m.ascender > prevBottom)
                #expect(Double(layout.textLeft) + m.textWidth <= Double(layout.bounds.right))
                prevBottom = Double(row.baselineY) + abs(m.descender)
            }
            #expect(prevBottom < Double(layout.bounds.bottom))
        }
    }

    @Test("Resize, fillFullsize, combine, and caption rendering produce valid Core Graphics output")
    func coreGraphicsPipeline() throws {
        let landscape = makeSolidImage(width: 2000, height: 1000, r: 1, g: 0, b: 0)
        let resizedLandscape = try ImageProcessor.resize(landscape)
        #expect(resizedLandscape.width == 1080)
        #expect(resizedLandscape.height == 540)

        let portrait = makeSolidImage(width: 800, height: 1600, r: 0, g: 0.5, b: 1)
        let resizedPortrait = try ImageProcessor.resize(portrait)
        #expect(resizedPortrait.width == 960)
        #expect(resizedPortrait.height == 1920)

        let filled = try ImageProcessor.fillFullsize(resizedPortrait)
        #expect(filled.width == 1080)
        #expect(filled.height == 1920)

        let combined = try ImageProcessor.combine(resizedLandscape, resizedLandscape)
        #expect(combined.width == 1080)
        #expect(combined.height == 1920)

        // Caption with park ride icon on landscape & panorama
        let photo = PhotoMetadata(
            uuid: "epcot-1",
            date: Date(timeIntervalSince1970: 1_602_979_200),
            width: 1080,
            height: 540,
            persons: ["Robert Smith", "Jane Doe"],
            placeName: "EPCOT",
            areasOfInterest: ["Living with the Land"]
        )
        let white = makeSolidImage(width: 1080, height: 540, r: 1, g: 1, b: 1)
        let (captioned, layout) = try ImageProcessor.addCaption(
            to: white,
            photo: photo,
            personAliases: ["Robert Smith": "Pap"]
        )
        #expect(captioned.width == 1080)
        #expect(captioned.height == 540)
        #expect(layout.iconName == "ride-epcot-living-with-the-land")
        #expect(layout.rows.first?.text == "Pap, Jane")
        #expect(layout.rows.last?.text.contains("EPCOT · Living with the Land") == true)
    }

    @Test("Landscape frame orientation resizes, fills 1920x1080, and combines portraits side-by-side")
    func landscapeFramePipeline() throws {
        let landscape = makeSolidImage(width: 2400, height: 1200, r: 0.2, g: 0.6, b: 0.8)
        let resizedLandscape = try ImageProcessor.resize(landscape, orientation: .landscape)
        #expect(resizedLandscape.width == 1920)
        #expect(resizedLandscape.height == 960)

        let filledLandscape = try ImageProcessor.fillFullsize(resizedLandscape, orientation: .landscape)
        #expect(filledLandscape.width == 1920)
        #expect(filledLandscape.height == 1080)

        let portrait = makeSolidImage(width: 1200, height: 1800, r: 0.8, g: 0.3, b: 0.2)
        let resizedPortrait = try ImageProcessor.resize(portrait, orientation: .landscape)
        #expect(resizedPortrait.height == 1080)
        #expect(resizedPortrait.width == 720)

        let combinedSideBySide = try ImageProcessor.combine(resizedPortrait, resizedPortrait, orientation: .landscape)
        #expect(combinedSideBySide.width == 1920)
        #expect(combinedSideBySide.height == 1080)

        // Near-square portraits that exceed 1920 width together scale down proportionally without overlapping
        let nearSquare = makeSolidImage(width: 1000, height: 1050, r: 0.4, g: 0.4, b: 0.9)
        let combinedNearSquare = try ImageProcessor.combine(nearSquare, nearSquare, orientation: .landscape)
        #expect(combinedNearSquare.width == 1920)
        #expect(combinedNearSquare.height == 1080)
    }

    @Test("Single oversized name preserves omitted count")
    func singleOversizedName() {
        let text = ImageProcessor.fitCaptionNames(
            persons: [String(repeating: "A", count: 100), "Jane Doe", "Sam Brown"],
            includeList: nil,
            maxWidth: 300,
            fontSize: 36,
            measurer: MockMeasurer()
        )
        #expect(text.hasSuffix("... +2 others"))
    }
}
