import Foundation
import Testing
import UIKit
@testable import Actuali

struct AccountIconPhotoCropGeometryTests {
    @Test func dragStopsAtImageEdge() {
        let imageSize = CGSize(width: 1024, height: 768)
        let side: CGFloat = 320
        let fitScale = max(side / imageSize.width, side / imageSize.height)

        let offset = AccountIconPhotoCropGeometry.clampedOffset(
            CGSize(width: 200, height: -100),
            side: side,
            imageSize: imageSize,
            fitScale: fitScale,
            zoom: 1
        )

        #expect(abs(offset.width - (imageSize.width * fitScale - side) / 2) < 0.001)
        #expect(offset.height == 0)
    }

    @Test func cropRectTracksImagePositionAndRejectsInvalidSizes() {
        let imageSize = CGSize(width: 1024, height: 768)
        let rect = AccountIconPhotoCropGeometry.cropRect(
            imageSize: imageSize,
            viewportSide: 320,
            zoom: 1,
            offset: CGSize(width: 20, height: 0)
        )

        #expect(rect != nil)
        #expect(abs((rect?.origin.x ?? 0) - 80) < 0.001)
        #expect(abs((rect?.midX ?? 0) - 464) < 0.001)
        #expect(abs((rect?.origin.y ?? 0)) < 0.001)
        #expect(abs((rect?.width ?? 0) - 768) < 0.001)
        #expect(AccountIconPhotoCropGeometry.cropRect(
            imageSize: .zero, viewportSide: 320, zoom: 1, offset: .zero
        ) == nil)
    }
}
