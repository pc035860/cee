import XCTest
@testable import Cee

@MainActor
final class ImageSlotViewTests: XCTestCase {

    var slot: ImageSlotView!

    override func setUp() {
        super.setUp()
        slot = ImageSlotView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    }

    override func tearDown() {
        slot = nil
        super.tearDown()
    }

    // MARK: - Helper

    /// Creates a valid NSImage with actual pixel content
    private func createTestImage(width: Int, height: Int) -> NSImage {
        let bitmap = NSBitmapImageRep(
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
        )!
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = ctx
        ctx.cgContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    // MARK: - Lifecycle Tests

    func testPrepareForReuse_clearsImageIndex() {
        // Given
        slot.imageIndex = 5

        // When
        slot.prepareForReuse()

        // Then
        XCTAssertEqual(slot.imageIndex, -1, "imageIndex should be reset to -1 after prepareForReuse")
    }

    func testPrepareForReuse_clearsLayerContents() {
        // Given
        let image = createTestImage(width: 50, height: 50)
        slot.setImage(image)
        // Force immediate layer update
        slot.display()
        XCTAssertNotNil(slot.layer?.contents, "Layer should have contents after setImage")

        // When
        slot.prepareForReuse()
        slot.display()  // Force layer update to reflect cleared state

        // Then
        XCTAssertNil(slot.layer?.contents, "Layer contents should be nil after prepareForReuse")
    }

    func testSetImage_updatesLayerContents() {
        // Given
        let image = createTestImage(width: 50, height: 50)

        // When
        slot.setImage(image)
        slot.display()  // Force immediate layer update

        // Then
        XCTAssertNotNil(slot.layer?.contents, "Layer should have contents after setImage")
    }

    func testSetImage_withNil_clearsLayerContents() {
        // Given
        let image = createTestImage(width: 50, height: 50)
        slot.setImage(image)
        slot.display()
        XCTAssertNotNil(slot.layer?.contents, "Layer should have contents after initial setImage")

        // When
        slot.setImage(nil)
        slot.display()

        // Then
        XCTAssertNil(slot.layer?.contents, "Layer contents should be nil after setImage(nil)")
    }

    // MARK: - Task Management Tests

    func testSetLoadTask_cancelsPreviousTask() async {
        // Given
        var firstTaskCancelled = false
        let firstTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            firstTaskCancelled = Task.isCancelled
        }
        slot.setLoadTask(firstTask)

        // When
        let secondTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        slot.setLoadTask(secondTask)

        // Give time for cancellation to propagate
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Then
        XCTAssertTrue(firstTaskCancelled, "First task should be cancelled when second task is set")
    }

    func testPrepareForReuse_cancelsLoadTask() async {
        // Given
        var taskCancelled = false
        let task = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            taskCancelled = Task.isCancelled
        }
        slot.setLoadTask(task)

        // When
        slot.prepareForReuse()

        // Give time for cancellation to propagate
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Then
        XCTAssertTrue(taskCancelled, "Task should be cancelled when prepareForReuse is called")
    }

    // MARK: - Layer Configuration Tests

    func testWantsUpdateLayer_returnsTrue() {
        XCTAssertTrue(slot.wantsUpdateLayer, "ImageSlotView should return true for wantsUpdateLayer")
    }

    func testLayerContentsGravity_isResize() {
        XCTAssertEqual(slot.layer?.contentsGravity, .resize, "Layer contentsGravity should be .resize for fit-to-width")
    }
}
