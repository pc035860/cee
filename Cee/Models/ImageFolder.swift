import Foundation
import UniformTypeIdentifiers

class ImageFolder {
    let folderURL: URL
    private(set) var images: [ImageItem] = []
    var currentIndex: Int = 0

    static let supportedTypes: Set<UTType> = [
        .jpeg, .png, .tiff, .heic, .heif, .gif, .webP, .bmp
    ]

    init(containing fileURL: URL) {
        self.folderURL = fileURL.deletingLastPathComponent()
        self.images = scanFolder()
        self.currentIndex = images.firstIndex { $0.url == fileURL } ?? 0
    }

    private func scanFolder() -> [ImageItem] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.contentTypeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { url in
                guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                else { return false }
                return Self.supportedTypes.contains(where: { type.conforms(to: $0) })
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { ImageItem(url: $0) }
    }

    var currentImage: ImageItem? { images[safe: currentIndex] }
    var hasNext: Bool { currentIndex < images.count - 1 }
    var hasPrevious: Bool { currentIndex > 0 }

    @discardableResult
    func goNext() -> Bool {
        guard hasNext else { return false }
        currentIndex += 1
        return true
    }

    @discardableResult
    func goPrevious() -> Bool {
        guard hasPrevious else { return false }
        currentIndex -= 1
        return true
    }
}
