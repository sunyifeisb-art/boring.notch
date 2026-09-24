//
//  ImageService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-13.
//

import Foundation
import Defaults

public protocol ImageServiceProtocol {
    func fetchImageData(from url: URL) async throws -> Data
}

public final class ImageService: ImageServiceProtocol {
    public static let shared = ImageService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        // Artwork is small and short-lived. Keep the in-memory budget modest;
        // the disk cache handles reuse without reserving 50 MB in the app.
        let cache = URLCache(memoryCapacity: 8 * 1024 * 1024, // 8 MB
                             diskCapacity: 100 * 1024 * 1024, // 100MB
                             diskPath: "artwork_cache")
        config.urlCache = cache
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)

        performLegacyCacheCleanupIfNeeded()
    }

    private func performLegacyCacheCleanupIfNeeded() {

        if !Defaults[.didClearLegacyURLCacheV1] {
            URLCache.shared.removeAllCachedResponses()
            Defaults[.didClearLegacyURLCacheV1] = true
        }
    }

    public func fetchImageData(from url: URL) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw URLError(.unsupportedURL)
        }
        let (data, _) = try await session.data(from: url)
        return data
    }
}
