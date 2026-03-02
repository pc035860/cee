import XCTest
@testable import Cee

final class ImageFolderSupportedTypesTests: XCTestCase {

    // MARK: - Supported Formats

    func testIsSupported_jpeg() {
        let url = URL(fileURLWithPath: "/tmp/image.jpg")
        XCTAssertTrue(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_jpegUppercase() {
        let url = URL(fileURLWithPath: "/tmp/image.JPEG")
        XCTAssertTrue(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_png() {
        let url = URL(fileURLWithPath: "/tmp/image.png")
        XCTAssertTrue(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_heic() {
        let url = URL(fileURLWithPath: "/tmp/image.heic")
        XCTAssertTrue(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_heif() {
        let url = URL(fileURLWithPath: "/tmp/image.heif")
        XCTAssertTrue(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_tiff() {
        let url = URL(fileURLWithPath: "/tmp/image.tiff")
        XCTAssertTrue(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_gif() {
        let url = URL(fileURLWithPath: "/tmp/image.gif")
        XCTAssertTrue(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_webP() {
        let url = URL(fileURLWithPath: "/tmp/image.webp")
        XCTAssertTrue(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_bmp() {
        let url = URL(fileURLWithPath: "/tmp/image.bmp")
        XCTAssertTrue(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_pdf() {
        let url = URL(fileURLWithPath: "/tmp/document.pdf")
        XCTAssertTrue(ImageFolder.isSupported(url: url))
    }

    // MARK: - Unsupported Formats

    func testIsSupported_txt_returnsFalse() {
        let url = URL(fileURLWithPath: "/tmp/file.txt")
        XCTAssertFalse(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_mp4_returnsFalse() {
        let url = URL(fileURLWithPath: "/tmp/video.mp4")
        XCTAssertFalse(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_doc_returnsFalse() {
        let url = URL(fileURLWithPath: "/tmp/document.doc")
        XCTAssertFalse(ImageFolder.isSupported(url: url))
    }

    // MARK: - Edge Cases

    func testIsSupported_caseInsensitive() {
        XCTAssertTrue(ImageFolder.isSupported(url: URL(fileURLWithPath: "/tmp/image.JPG")))
        XCTAssertTrue(ImageFolder.isSupported(url: URL(fileURLWithPath: "/tmp/image.PNG")))
        XCTAssertTrue(ImageFolder.isSupported(url: URL(fileURLWithPath: "/tmp/image.PDF")))
        XCTAssertTrue(ImageFolder.isSupported(url: URL(fileURLWithPath: "/tmp/image.HeIc")))
    }

    func testIsSupported_noExtension_returnsFalse() {
        let url = URL(fileURLWithPath: "/tmp/imagefile")
        XCTAssertFalse(ImageFolder.isSupported(url: url))
    }

    func testIsSupported_unknownExtension_returnsFalse() {
        let url = URL(fileURLWithPath: "/tmp/image.xyz")
        XCTAssertFalse(ImageFolder.isSupported(url: url))
    }
}
