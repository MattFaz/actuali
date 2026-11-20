import Combine
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AccountIconCustomization: Codable, Equatable {
    var symbolName: String?
    var tintHex: String
    var photoFilename: String?

    static let defaultTint = "3478F6"
}

/// Device-local account appearance. Both settings and files are namespaced by
/// budget and account, and never enter Actual's synced database.
@MainActor
final class AccountIconCustomizationStore: ObservableObject {
    static let shared = AccountIconCustomizationStore()

    @Published private(set) var revision = 0
    @Published private(set) var photoRevision = 0
    private let defaults: UserDefaults
    private let fileManager = FileManager.default
    private let applicationSupportDirectory: URL
    private let imageCache = NSCache<NSString, UIImage>()
    private var imageCacheKeysByBudget: [String: Set<String>] = [:]
    private var cachedCustomizations: [String: AccountIconCustomization] = [:]
    private var loadedCustomizationKeys: Set<String> = []
    private var iconsEnabledByBudget: [String: Bool] = [:]
    private let imageEncoder = AccountIconImageEncoder.shared

    init(defaults: UserDefaults = .standard, applicationSupportDirectory: URL? = nil) {
        self.defaults = defaults
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    func iconsEnabled(for budgetID: String?) -> Bool {
        guard let budgetID else { return true }
        if let cached = iconsEnabledByBudget[budgetID] {
            return cached
        }
        if let saved = defaults.object(forKey: enabledKey(budgetID)) as? Bool {
            iconsEnabledByBudget[budgetID] = saved
            return saved
        }
        // One-time migration: the previous preference was global. Assign it
        // to the currently open budget, then remove the global key so it can
        // never affect another budget.
        if let legacy = defaults.object(forKey: "showAccountTypeIcons") as? Bool {
            defaults.set(legacy, forKey: enabledKey(budgetID))
            defaults.removeObject(forKey: "showAccountTypeIcons")
            iconsEnabledByBudget[budgetID] = legacy
            return legacy
        }
        iconsEnabledByBudget[budgetID] = true
        return true
    }

    func setIconsEnabled(_ enabled: Bool, for budgetID: String?) {
        guard let budgetID else { return }
        defaults.set(enabled, forKey: enabledKey(budgetID))
        iconsEnabledByBudget[budgetID] = enabled
        revision &+= 1
    }

    func customization(for budgetID: String?, accountID: String) -> AccountIconCustomization? {
        guard let budgetID else { return nil }
        let key = customizationKey(budgetID, accountID)
        if loadedCustomizationKeys.contains(key) {
            return cachedCustomizations[key]
        }
        loadedCustomizationKeys.insert(key)
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(AccountIconCustomization.self, from: data) else { return nil }
        cachedCustomizations[key] = value
        return value
    }

    func image(for budgetID: String?, accountID: String) -> UIImage? {
        guard let budgetID else { return nil }
        return imageCache.object(forKey: customizationKey(budgetID, accountID) as NSString)
    }

    /// Reads and downsizes a photo away from the UI thread. Views call this
    /// when an account with a custom photo appears; repeated redraws use cache.
    func loadImage(for budgetID: String?, accountID: String) async -> UIImage? {
        guard let budgetID,
              let filename = customization(for: budgetID, accountID: accountID)?.photoFilename
        else { return nil }
        let key = customizationKey(budgetID, accountID)
        if let cached = imageCache.object(forKey: key as NSString) {
            return cached
        }
        guard let data = await imageEncoder.jpegThumbnail(
            at: photoFileURL(for: budgetID, accountID: accountID), maxPixelSize: 512, quality: 0.82
        ),
            customization(for: budgetID, accountID: accountID)?.photoFilename == filename,
            let image = UIImage(data: data) else { return nil }
        cache(image, key: key, budgetID: budgetID)
        return image
    }

    func setSymbol(_ symbol: String, tintHex: String, budgetID: String?, accountID: String) {
        guard let budgetID else { return }
        var value = customization(for: budgetID, accountID: accountID)
            ?? AccountIconCustomization(symbolName: nil, tintHex: AccountIconCustomization.defaultTint, photoFilename: nil)
        removePhoto(value, budgetID: budgetID, accountID: accountID)
        value.symbolName = symbol
        value.tintHex = tintHex
        value.photoFilename = nil
        save(value, budgetID: budgetID, accountID: accountID)
    }

    func setTint(_ tintHex: String, budgetID: String?, accountID: String) {
        guard let budgetID else { return }
        var value = customization(for: budgetID, accountID: accountID)
            ?? AccountIconCustomization(symbolName: nil, tintHex: AccountIconCustomization.defaultTint, photoFilename: nil)
        value.tintHex = tintHex
        save(value, budgetID: budgetID, accountID: accountID)
    }

    func setPhoto(_ imageData: Data, budgetID: String?, accountID: String) async -> Bool {
        guard let budgetID,
              let jpeg = await imageEncoder.jpegThumbnail(from: imageData, maxPixelSize: 512, quality: 0.82),
              let image = UIImage(data: jpeg) else { return false }
        let fileURL = photoFileURL(for: budgetID, accountID: accountID)
        guard await imageEncoder.write(jpeg, to: fileURL) else { return false }

        var value = customization(for: budgetID, accountID: accountID)
            ?? AccountIconCustomization(symbolName: nil, tintHex: AccountIconCustomization.defaultTint, photoFilename: nil)
        value.symbolName = nil
        value.photoFilename = fileURL.lastPathComponent
        let key = customizationKey(budgetID, accountID)
        cache(image, key: key, budgetID: budgetID)
        save(value, budgetID: budgetID, accountID: accountID)
        photoRevision &+= 1
        return true
    }

    /// Stable URL used for local files and storage tests.
    func photoFileURL(for budgetID: String, accountID: String) -> URL {
        folder(for: budgetID).appendingPathComponent(safeComponent(accountID) + ".jpg")
    }

    func clear(accountID: String, budgetID: String?) {
        guard let budgetID else { return }
        if let old = customization(for: budgetID, accountID: accountID) {
            removePhoto(old, budgetID: budgetID, accountID: accountID)
        } else {
            removeCachedImage(budgetID: budgetID, accountID: accountID)
        }
        let key = customizationKey(budgetID, accountID)
        defaults.removeObject(forKey: key)
        cachedCustomizations.removeValue(forKey: key)
        loadedCustomizationKeys.insert(key)
        revision &+= 1
    }

    func clear(budgetID: String) {
        defaults.removeObject(forKey: enabledKey(budgetID))
        try? fileManager.removeItem(at: folder(for: budgetID))
        clearCachedImages(budgetID: budgetID)
        let prefix = customizationPrefix(budgetID)
        cachedCustomizations = cachedCustomizations.filter { !$0.key.hasPrefix(prefix) }
        loadedCustomizationKeys = loadedCustomizationKeys.filter { !$0.hasPrefix(prefix) }
        iconsEnabledByBudget.removeValue(forKey: budgetID)
        // Metadata keys are intentionally local and only cleared for this budget.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        photoRevision &+= 1
        revision &+= 1
    }

    func prune(accounts: Set<String>, budgetID: String?) {
        guard let budgetID else { return }
        var didRemoveCustomization = false
        let prefix = customizationPrefix(budgetID)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let accountID = String(key.dropFirst(prefix.count))
            guard !accounts.contains(accountID) else { continue }
            if let data = defaults.data(forKey: key),
               let value = try? JSONDecoder().decode(AccountIconCustomization.self, from: data) {
                removePhoto(value, budgetID: budgetID, accountID: accountID)
            } else {
                removeCachedImage(budgetID: budgetID, accountID: accountID)
            }
            defaults.removeObject(forKey: key)
            cachedCustomizations.removeValue(forKey: key)
            loadedCustomizationKeys.insert(key)
            didRemoveCustomization = true
        }
        if didRemoveCustomization {
            photoRevision &+= 1
            revision &+= 1
        }
    }

    private func cache(_ image: UIImage, key: String, budgetID: String) {
        imageCache.setObject(image, forKey: key as NSString)
        imageCacheKeysByBudget[budgetID, default: []].insert(key)
    }

    private func removeCachedImage(budgetID: String, accountID: String) {
        let key = customizationKey(budgetID, accountID)
        imageCache.removeObject(forKey: key as NSString)
        imageCacheKeysByBudget[budgetID]?.remove(key)
        if imageCacheKeysByBudget[budgetID]?.isEmpty == true {
            imageCacheKeysByBudget.removeValue(forKey: budgetID)
        }
    }

    private func clearCachedImages(budgetID: String) {
        for key in imageCacheKeysByBudget.removeValue(forKey: budgetID) ?? [] {
            imageCache.removeObject(forKey: key as NSString)
        }
    }

    private func removePhoto(_ value: AccountIconCustomization, budgetID: String, accountID: String) {
        if let filename = value.photoFilename {
            try? fileManager.removeItem(at: folder(for: budgetID).appendingPathComponent(filename))
            photoRevision &+= 1
        }
        removeCachedImage(budgetID: budgetID, accountID: accountID)
    }

    private func folder(for budgetID: String) -> URL {
        applicationSupportDirectory.appendingPathComponent("AccountIcons", isDirectory: true)
            .appendingPathComponent(safeComponent(budgetID), isDirectory: true)
    }

    private func safeComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
    }

    private func enabledKey(_ budgetID: String) -> String {
        "showAccountTypeIcons.\(budgetID)"
    }

    private func customizationPrefix(_ budgetID: String) -> String {
        "accountIcon.\(budgetID)."
    }

    private func customizationKey(_ budgetID: String, _ accountID: String) -> String {
        customizationPrefix(budgetID) + accountID
    }

    private func save(_ value: AccountIconCustomization, budgetID: String, accountID: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let key = customizationKey(budgetID, accountID)
        defaults.set(data, forKey: key)
        cachedCustomizations[key] = value
        loadedCustomizationKeys.insert(key)
        revision &+= 1
    }
}

actor AccountIconImageEncoder {
    static let shared = AccountIconImageEncoder()

    func jpegThumbnail(from data: Data, maxPixelSize: Int, quality: Float) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpegThumbnail(from: source, maxPixelSize: maxPixelSize, quality: quality)
    }

    func jpegThumbnail(at url: URL, maxPixelSize: Int, quality: Float) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return jpegThumbnail(from: source, maxPixelSize: maxPixelSize, quality: quality)
    }

    func cropPhoto(from data: Data, side: CGFloat, zoom: CGFloat, offset: CGSize) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let rect = AccountIconPhotoCropGeometry.cropRect(
                  imageSize: CGSize(width: image.width, height: image.height),
                  viewportSide: side,
                  zoom: zoom,
                  offset: offset
              ),
              let cropped = image.cropping(to: rect) else { return nil }
        return jpegData(cropped, quality: 0.92)
    }

    func write(_ jpeg: Data, to fileURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try jpeg.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func jpegThumbnail(from source: CGImageSource, maxPixelSize: Int, quality: Float) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpegData(image, quality: quality)
    }

    private func jpegData(_ image: CGImage, quality: Float) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
