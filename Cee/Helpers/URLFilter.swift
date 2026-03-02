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
}
