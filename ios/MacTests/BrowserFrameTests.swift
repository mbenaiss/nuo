import XCTest

final class BrowserFrameTests: XCTestCase {
    /// `[kind, reserved, width u16le, height u16le, reserved u16]` then the JPEG.
    private func message(kind: UInt8 = BrowserFrameWire.kind, width: Int, height: Int, jpeg: [UInt8]) -> Data {
        var bytes: [UInt8] = [kind, 0]
        bytes += [UInt8(width & 0xFF), UInt8(width >> 8 & 0xFF)]
        bytes += [UInt8(height & 0xFF), UInt8(height >> 8 & 0xFF)]
        bytes += [0, 0]
        return Data(bytes + jpeg)
    }

    func testTheHeaderGivesThePageSizeAndTheJpegFollowsIt() {
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x11, 0x22]
        let split = BrowserFrameWire.split(message(width: 1280, height: 712, jpeg: jpeg))
        XCTAssertEqual(split?.size, CGSize(width: 1280, height: 712))
        XCTAssertEqual(split.map { [UInt8]($0.jpeg) }, jpeg)
    }

    func testAWideViewportIsReadAsLittleEndian() {
        let split = BrowserFrameWire.split(message(width: 1600, height: 1200, jpeg: [0xFF, 0xD8]))
        XCTAssertEqual(split?.size, CGSize(width: 1600, height: 1200))
    }

    func testAFrameWithoutItsSizeFallsBackInsteadOfCollapsing() {
        let split = BrowserFrameWire.split(message(width: 0, height: 0, jpeg: [0xFF, 0xD8]))
        XCTAssertEqual(split?.size, BrowserFrameWire.fallbackSize)
    }

    func testAnythingThatIsNotAFrameIsIgnored() {
        // Another kind: a later message type must not be read as pixels.
        XCTAssertNil(BrowserFrameWire.split(message(kind: 2, width: 800, height: 600, jpeg: [0xFF, 0xD8])))
        // Header only, no image, and shorter than a header.
        XCTAssertNil(BrowserFrameWire.split(message(width: 800, height: 600, jpeg: [])))
        XCTAssertNil(BrowserFrameWire.split(Data([BrowserFrameWire.kind, 0, 0x20])))
        XCTAssertNil(BrowserFrameWire.split(Data()))
    }
}
