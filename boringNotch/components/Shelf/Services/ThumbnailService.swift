//
//  ThumbnailService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-07.
//

import Foundation
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

actor ThumbnailService {
    static let shared = ThumbnailService()

    private struct CachedThumbnail {
        let image: NSImage
        let path: String
        let estimatedCost: Int
        var lastAccess: UInt64
    }

    private var cache: [String: CachedThumbnail] = [:]
    private var cachedCost = 0
    private var accessCounter: UInt64 = 0
    private var pendingRequests: [String: Task<NSImage?, Never>] = [:]
    private let thumbnailGenerator = QLThumbnailGenerator.shared
    private let maximumCacheEntries = 64
    private let maximumCacheCost = 16 * 1024 * 1024

    private init() {}
    
    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let cacheKey = "\(url.path)_\(size.width)x\(size.height)"
        
        if var cached = cache[cacheKey] {
            accessCounter &+= 1
            cached.lastAccess = accessCounter
            cache[cacheKey] = cached
            return cached.image
        }
        
        if let pending = pendingRequests[cacheKey] {
            return await pending.value
        }
        
        let task = Task<NSImage?, Never> {
            let thumbnail = await generateQuickLookThumbnail(for: url, size: size)
            if let thumbnail = thumbnail {
                self.insert(thumbnail, for: cacheKey, path: url.path, size: size)
            }
            pendingRequests[cacheKey] = nil
            return thumbnail
        }
        
        pendingRequests[cacheKey] = task
        return await task.value
    }
    
    func clearCache() {
        cache.removeAll()
        cachedCost = 0
    }

    func clearCache(for url: URL) {
        let keys = cache.compactMap { key, entry in
            entry.path == url.path ? key : nil
        }
        for key in keys {
            if let removed = cache.removeValue(forKey: key) {
                cachedCost -= removed.estimatedCost
            }
        }
    }

    private func insert(_ image: NSImage, for key: String, path: String, size: CGSize) {
        accessCounter &+= 1
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let estimatedCost = max(1, Int(size.width * size.height * scale * scale * 4))
        if let replaced = cache.removeValue(forKey: key) {
            cachedCost -= replaced.estimatedCost
        }
        cache[key] = CachedThumbnail(
            image: image,
            path: path,
            estimatedCost: estimatedCost,
            lastAccess: accessCounter
        )
        cachedCost += estimatedCost

        while cache.count > maximumCacheEntries || cachedCost > maximumCacheCost {
            guard let oldestKey = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key,
                  let evicted = cache.removeValue(forKey: oldestKey)
            else { break }
            cachedCost -= evicted.estimatedCost
        }
    }
    
    // MARK: - Private Methods
    
    private func generateQuickLookThumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        
        return await url.accessSecurityScopedResource { scopedURL in
            NSLog("🔐 ThumbnailService: obtaining security scope for \(scopedURL.path)")
            let request = QLThumbnailGenerator.Request(
                fileAt: scopedURL,
                size: size,
                scale: scale,
                representationTypes: .all
            )
            request.iconMode = true

            return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                thumbnailGenerator.generateBestRepresentation(for: request) { representation, error in
                    if let rep = representation {
                        NSLog("🔍 ThumbnailService: generated thumbnail for \(scopedURL.path)")
                        continuation.resume(returning: rep.nsImage)
                    } else {
                        if let err = error { 
                            NSLog("⚠️ ThumbnailService: thumbnail error for \(scopedURL.path): \(err.localizedDescription)") 
                        }
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

// MARK: - Extensions

extension QLThumbnailRepresentation {
    var nsImage: NSImage {
        return NSImage(cgImage: self.cgImage, size: self.cgImage.size)
    }
}

extension CGImage {
    var size: NSSize {
        return NSSize(width: self.width, height: self.height)
    }
}
