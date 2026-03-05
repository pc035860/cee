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
/// Creates a JPEG file of given dimensions (for SubsampleFactor tests).
/// Returns temp file URL. Caller should delete when done.
func createJPEG(width: Int, height: Int) throws -> URL {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 3,
        hasAlpha: false,
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
    guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
        throw NSError(domain: "TestHelpers", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JPEG"])
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try jpegData.write(to: url)
    return url
}

/// Creates a PNG file of given dimensions (for thumbnail / resize tests).
/// Returns temp file URL. Caller should delete when done.
func createPNG(width: Int, height: Int) throws -> URL {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
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
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "TestHelpers", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try pngData.write(to: url)
    return url
}
#endif
