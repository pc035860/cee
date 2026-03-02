import Foundation

/// Pure logic helper for filtering URLs by file type.
/// Extracted from EmptyStateView for testability.
struct URLFilter {

    /// Filter URLs to only include supported image/PDF types.
    /// - Parameters:
    ///   - urls: URLs to filter
    ///   - isSupported: Closure that determines if a URL is supported
    /// - Returns: Array of URLs that pass the filter
    static func filterImageURLs(_ urls: [URL], isSupported: (URL) -> Bool) -> [URL] {
        urls.filter { isSupported($0) }
    }

    /// Check if a URL is a directory.
    /// - Parameter url: URL to check
    /// - Returns: true if the URL points to a directory
    static func isDirectory(_ url: URL) -> Bool {
        guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              let isDirectory = resourceValues.isDirectory else { return false }
        return isDirectory
    }

    /// Filter URLs to include supported images AND folders.
    /// Used for drag-drop to accept both files and folders.
    /// - Parameters:
    ///   - urls: URLs to filter
    ///   - isSupported: Closure that determines if a file URL is supported
    /// - Returns: Array of URLs (folders or supported files)
    static func filterImageAndFolderURLs(_ urls: [URL], isSupported: (URL) -> Bool) -> [URL] {
        urls.filter { url in
            isDirectory(url) || isSupported(url)
        }
    }
}
