import XCTest
import UIKit
import ImageIO
import ReedApplication
@testable import Reed

@MainActor final class PhotoProcessorTests: XCTestCase {
    func testCropChangesStoredImageButRetainsWholePagePreview() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 400,height: 200),format:format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x:0,y:0,width:400,height:200))
            UIColor.black.setFill(); context.fill(CGRect(x:0,y:0,width:100,height:200))
        }.jpegData(compressionQuality:1))
        let processor = PhotoProcessor()
        let whole = try await processor.process(data,region:PhotoRegion())
        XCTAssertEqual(whole.original,data); XCTAssertNil(whole.preview)
        let crop = try await processor.process(data,region:PhotoRegion(x:0,y:0,width:0.25,height:1))
        let image = try XCTUnwrap(UIImage(data:crop.original))
        XCTAssertEqual(image.size.width,100); XCTAssertEqual(image.size.height,200)
        XCTAssertEqual(try XCTUnwrap(UIImage(data:try XCTUnwrap(crop.preview))).size.width,400)
    }
}
