import Foundation
import SwiftUI
import UIKit
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreCategoryStatusDotsTests {

    @Test func categoryStatusDotsShowByDefault() {
        #expect(BudgetStore.previewInstance().showCategoryStatusDots)
    }

    @Test func customColorPersistsAndLoadsFromUserDefaults() {
        let key = "categoryStatusDotColors"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = BudgetStore.previewInstance()
        let selectedColor = Color(red: 1, green: 0.25, blue: 0.5)
        store.setCategoryStatusDotColor(selectedColor, for: .overspent)

        let colors = UserDefaults.standard.dictionary(forKey: key) as? [String: Data]
        #expect(colors?["overspent"] != nil)

        let reloadedStore = BudgetStore.previewInstanceLoadingPersistedPreferencesForTesting()
        let restoredColor = reloadedStore.categoryStatusDotColor(for: .overspent)

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(UIColor(restoredColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(abs(Double(red) - 1.0) < 0.01)
        #expect(abs(Double(green) - 0.25) < 0.01)
        #expect(abs(Double(blue) - 0.5) < 0.01)
        #expect(abs(Double(alpha) - 1.0) < 0.01)
    }

    @Test func unrecognizedRGBColorSpaceDoesNotBecomeGrayscale() {
        let key = "categoryStatusDotColors"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.genericRGBLinear)!
        let cgColor = CGColor(
            colorSpace: colorSpace,
            components: [0.9, 0.2, 0.1, 1]
        )!
        let store = BudgetStore.previewInstance()
        store.setCategoryStatusDotColor(Color(UIColor(cgColor: cgColor)), for: .overspent)

        let reloadedStore = BudgetStore.previewInstanceLoadingPersistedPreferencesForTesting()
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(UIColor(reloadedStore.categoryStatusDotColor(for: .overspent)).getRed(
            &red, green: &green, blue: &blue, alpha: &alpha
        ))
        #expect(red > green)
        #expect(green > blue)
    }



    @Test func customColorsRoundTripForEveryProgressState() {
        let key = "categoryStatusDotColors"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = BudgetStore.previewInstance()
        let colors: [CategoryProgressState: Color] = [
            .overspent: Color(red: 0.91, green: 0.12, blue: 0.18),
            .spent: Color(red: 0.87, green: 0.36, blue: 0.14),
            .spending: Color(red: 0.16, green: 0.42, blue: 0.92),
            .funded: Color(red: 0.12, green: 0.68, blue: 0.28),
            .unassigned: Color(red: 0.40, green: 0.42, blue: 0.46),
        ]

        for (state, color) in colors {
            store.setCategoryStatusDotColor(color, for: state)
        }

        let reloadedStore = BudgetStore.previewInstanceLoadingPersistedPreferencesForTesting()

        for (state, color) in colors {
            var expectedRed: CGFloat = 0
            var expectedGreen: CGFloat = 0
            var expectedBlue: CGFloat = 0
            var expectedAlpha: CGFloat = 0
            var restoredRed: CGFloat = 0
            var restoredGreen: CGFloat = 0
            var restoredBlue: CGFloat = 0
            var restoredAlpha: CGFloat = 0

            #expect(UIColor(color).getRed(
                &expectedRed, green: &expectedGreen, blue: &expectedBlue, alpha: &expectedAlpha
            ))
            #expect(UIColor(reloadedStore.categoryStatusDotColor(for: state)).getRed(
                &restoredRed, green: &restoredGreen, blue: &restoredBlue, alpha: &restoredAlpha
            ))
            #expect(abs(Double(restoredRed - expectedRed)) < 0.01)
            #expect(abs(Double(restoredGreen - expectedGreen)) < 0.01)
            #expect(abs(Double(restoredBlue - expectedBlue)) < 0.01)
            #expect(abs(Double(restoredAlpha - expectedAlpha)) < 0.01)
        }
    }

    @Test func legacyArchivedColorIsMigrated() {
        let key = "categoryStatusDotColors"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let legacyColor = UIColor(displayP3Red: 0.92, green: 0.24, blue: 0.38, alpha: 1)
        let legacyData = try! NSKeyedArchiver.archivedData(
            withRootObject: legacyColor,
            requiringSecureCoding: true
        )
        UserDefaults.standard.set(["overspent": legacyData], forKey: key)

        let store = BudgetStore.previewInstanceLoadingPersistedPreferencesForTesting()
        let restoredColor = store.categoryStatusDotColor(for: .overspent)
        let restoredUIColor = UIColor(restoredColor)
        let originalComponents = legacyColor.cgColor.components ?? []
        let restoredComponents = restoredUIColor.cgColor.components ?? []

        #expect(restoredUIColor.cgColor.colorSpace?.isWideGamutRGB == true)
        #expect(restoredComponents.count == originalComponents.count)
        #expect(zip(restoredComponents, originalComponents).allSatisfy {
            abs(Double($0.0 - $0.1)) < 0.01
        })
        let persistedColors = UserDefaults.standard.dictionary(forKey: key) as? [String: Data]
        #expect(persistedColors?["overspent"] != legacyData)
    }

    @Test func legacyJSONColorIsMigrated() {
        let key = "categoryStatusDotColors"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let legacyPayload = #"{"red":1,"green":0.25,"blue":0.5,"alpha":1}"#
        UserDefaults.standard.set(["overspent": Data(legacyPayload.utf8)], forKey: key)

        let store = BudgetStore.previewInstanceLoadingPersistedPreferencesForTesting()
        let restoredColor = UIColor(store.categoryStatusDotColor(for: .overspent))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        #expect(restoredColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(abs(Double(red) - 1.0) < 0.01)
        #expect(abs(Double(green) - 0.25) < 0.01)
        #expect(abs(Double(blue) - 0.5) < 0.01)
        #expect(abs(Double(alpha) - 1.0) < 0.01)
        let persistedColors = UserDefaults.standard.dictionary(forKey: key) as? [String: Data]
        #expect(persistedColors?["overspent"] != Data(legacyPayload.utf8))
    }

    @Test func grayscaleColorRoundTrips() {
        let key = "categoryStatusDotColors"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = BudgetStore.previewInstance()
        let selectedColor = Color(white: 0.35)

        store.setCategoryStatusDotColor(selectedColor, for: .unassigned)

        let reloadedStore = BudgetStore.previewInstanceLoadingPersistedPreferencesForTesting()
        let restoredColor = UIColor(reloadedStore.categoryStatusDotColor(for: .unassigned))
        var white: CGFloat = 0
        var alpha: CGFloat = 0

        #expect(restoredColor.getWhite(&white, alpha: &alpha))
        #expect(abs(Double(white) - 0.35) < 0.01)
        #expect(abs(Double(alpha) - 1.0) < 0.01)
    }

    @Test func customColorCanBeResetToDefault() {
        let key = "categoryStatusDotColors"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = BudgetStore.previewInstance()
        store.setCategoryStatusDotColor(
            Color(red: 0.12, green: 0.34, blue: 0.56),
            for: .overspent
        )
        store.resetCategoryStatusDotColor(for: .overspent)

        #expect(UserDefaults.standard.dictionary(forKey: key)?["overspent"] == nil)
        #expect(UIColor(store.categoryStatusDotColor(for: .overspent)) == UIColor(.red))
    }

    @Test func invalidPersistedColorFallsBackToSystemTint() {
        let key = "categoryStatusDotColors"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set(["overspent": Data("not-json".utf8)], forKey: key)
        let store = BudgetStore.previewInstanceLoadingPersistedPreferencesForTesting()

        #expect(UIColor(store.categoryStatusDotColor(for: .overspent)) == UIColor(.red))
    }

    @Test func togglePersistsToUserDefaults() {
        let key = "showCategoryStatusDots"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = BudgetStore.previewInstance()
        store.showCategoryStatusDots = false
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == false)
        store.showCategoryStatusDots = true
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == true)
    }
}
