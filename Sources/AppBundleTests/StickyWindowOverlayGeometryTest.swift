@testable import AppBundle
import AppKit
import CoreVideo
import XCTest

final class StickyWindowOverlayGeometryTest: XCTestCase {
    func testStreamConfigurationPreservesWindowTransparency() {
        let configuration = makeStickyWindowStreamConfiguration(
            for: CGSize(width: 600, height: 400),
            scale: 2,
        )

        XCTAssertEqual(configuration.width, 1200)
        XCTAssertEqual(configuration.height, 800)
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_32BGRA)
        if #available(macOS 14.0, *) {
            XCTAssertFalse(configuration.shouldBeOpaque)
        }
    }

    func testFullSurfaceMapsDirectlyToDestination() {
        let geometry = StickyWindowCaptureGeometry(
            surfaceSize: CGSize(width: 1200, height: 800),
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            boundingRect: nil,
        )

        XCTAssertEqual(
            geometry.displayLayerFrame(in: CGSize(width: 600, height: 400)),
            CGRect(x: 0, y: 0, width: 600, height: 400),
        )
    }

    func testContentRectCropsSurfacePaddingWithoutChangingAspect() {
        let geometry = StickyWindowCaptureGeometry(
            surfaceSize: CGSize(width: 1200, height: 800),
            contentRect: CGRect(x: 100, y: 50, width: 1000, height: 700),
            boundingRect: nil,
        )

        XCTAssertEqual(
            geometry.displayLayerFrame(in: CGSize(width: 1000, height: 700)),
            CGRect(x: -100, y: -50, width: 1200, height: 800),
        )
    }

    func testAspectMismatchFillsAndCentersInsteadOfStretchingOrLetterboxing() {
        let geometry = StickyWindowCaptureGeometry(
            surfaceSize: CGSize(width: 1200, height: 800),
            contentRect: CGRect(x: 100, y: 50, width: 1000, height: 700),
            boundingRect: nil,
        )

        XCTAssertEqual(
            geometry.displayLayerFrame(in: CGSize(width: 1000, height: 600)),
            CGRect(x: -100, y: -100, width: 1200, height: 800),
        )
    }

    func testContentRectTakesPriorityOverBoundingRect() {
        let geometry = StickyWindowCaptureGeometry(
            surfaceSize: CGSize(width: 1200, height: 800),
            contentRect: CGRect(x: 100, y: 50, width: 1000, height: 700),
            boundingRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
        )

        XCTAssertEqual(geometry.cropRect, CGRect(x: 100, y: 50, width: 1000, height: 700))
    }

    func testBoundingRectIsFallbackForInvalidContentRect() {
        let geometry = StickyWindowCaptureGeometry(
            surfaceSize: CGSize(width: 1200, height: 800),
            contentRect: .zero,
            boundingRect: CGRect(x: 20, y: 10, width: 1160, height: 780),
        )

        XCTAssertEqual(geometry.cropRect, CGRect(x: 20, y: 10, width: 1160, height: 780))
    }

    func testInvalidMetadataFallsBackToWholeSurface() {
        let geometry = StickyWindowCaptureGeometry(
            surfaceSize: CGSize(width: 1200, height: 800),
            contentRect: CGRect(x: 1300, y: 0, width: 100, height: 100),
            boundingRect: nil,
        )

        XCTAssertEqual(geometry.cropRect, CGRect(x: 0, y: 0, width: 1200, height: 800))
    }
}
