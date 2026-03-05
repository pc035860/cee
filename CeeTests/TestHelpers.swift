import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Minimal valid 1x1 white PNG (67 bytes).
/// Shared across test cases that need real image files on disk.
func minimalPNG() -> Data {
    let bytes: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE,
        0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
        0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00,
        0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC, 0x33,
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
        0xAE, 0x42, 0x60, 0x82,
    ]
    return Data(bytes)
}

#if canImport(AppKit)

// MARK: - Image File Creation Helpers

/// Shared implementation for creating test image files of given dimensions.
/// Returns temp file URL. Caller should delete when done.
private func createImageFile(width: Int, height: Int,
                             fileType: NSBitmapImageRep.FileType,
                             properties: [NSBitmapImageRep.PropertyKey: Any],
                             hasAlpha: Bool,
                             extension ext: String) throws -> URL {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: hasAlpha ? 4 : 3,
        hasAlpha: hasAlpha,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw NSError(domain: "TestHelpers", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap"]) }
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.setFillColor(CGColor.white)
        ctx.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
    }
    guard let data = rep.representation(using: fileType, properties: properties) else {
        throw NSError(domain: "TestHelpers", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode \(ext)"])
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ext)
    try data.write(to: url)
    return url
}

/// Creates a JPEG file of given dimensions (for SubsampleFactor tests).
func createJPEG(width: Int, height: Int) throws -> URL {
    try createImageFile(width: width, height: height,
                        fileType: .jpeg, properties: [.compressionFactor: 0.8],
                        hasAlpha: false, extension: ".jpg")
}

/// Creates a PNG file of given dimensions (for thumbnail / resize tests).
func createPNG(width: Int, height: Int) throws -> URL {
    try createImageFile(width: width, height: height,
                        fileType: .png, properties: [:],
                        hasAlpha: true, extension: ".png")
}
#endif
