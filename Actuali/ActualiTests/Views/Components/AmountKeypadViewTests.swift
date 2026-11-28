import Testing
import UIKit
@testable import Actuali

struct AmountKeypadViewTests {
    /// The app bundle names its accent in Info.plist; Done must use that asset.
    @Test func doneKeyUsesTheAccentTheBuildNames() {
        let name = AmountKeypadView.accentColorName()
        #expect(name == Bundle.main.object(forInfoDictionaryKey: "NSAccentColorName") as? String)
        #expect(UIColor(named: name) != nil)
    }

    /// The test bundle has no NSAccentColorName, so the fallback applies.
    @Test func fallsBackToAccentColor() {
        let testBundle = Bundle(for: BundleToken.self)
        #expect(testBundle.object(forInfoDictionaryKey: "NSAccentColorName") == nil)
        #expect(AmountKeypadView.accentColorName(in: testBundle) == "AccentColor")
    }
}

private final class BundleToken {}
