import CoreGraphics
import Foundation

/// Reads the binary frames the gateway streams (`encodeFrame`, gateway/src/browser/viewer.ts).
enum BrowserFrameWire {
    static let headerBytes = 8
    static let kind: UInt8 = 1
    static let fallbackSize = CGSize(width: 1280, height: 720)

    /// The page area's CSS size from the header, and the JPEG that follows; nil when the message is not a frame.
    static func split(_ raw: Data) -> (size: CGSize, jpeg: Data)? {
        guard raw.count > headerBytes else { return nil }
        let header = [UInt8](raw.prefix(headerBytes))
        guard header[0] == kind else { return nil }
        let width = Int(header[2]) | Int(header[3]) << 8
        let height = Int(header[4]) | Int(header[5]) << 8
        let size = CGSize(width: width > 0 ? Double(width) : fallbackSize.width, height: height > 0 ? Double(height) : fallbackSize.height)
        return (size, Data(raw.dropFirst(headerBytes)))
    }
}
