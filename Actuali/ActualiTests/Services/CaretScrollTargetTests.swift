import Testing
import UIKit
@testable import Actuali

/// GH #674: the form keeps a growing text field's caret above the keyboard.
@MainActor
struct CaretScrollTargetTests {
    private func field(text: String) -> (UIScrollView, UIView, UITextView) {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let row = UIView(frame: CGRect(x: 0, y: 200, width: 320, height: 120))
        let textView = UITextView(frame: row.bounds)
        scrollView.addSubview(row)
        row.addSubview(textView)
        textView.text = text
        textView.selectedTextRange = textView.textRange(from: textView.endOfDocument, to: textView.endOfDocument)
        textView.layoutIfNeeded()
        return (scrollView, row, textView)
    }

    @Test func targetsTheCaretInTheEnclosingScrollView() throws {
        let (scrollView, row, textView) = field(text: "Lunch")
        let (target, rect) = try #require(AppDelegate.caretScrollTarget(for: textView))
        #expect(target === scrollView)
        #expect(rect.minY >= row.frame.minY - 12)
        #expect(rect.height < row.frame.height)
    }

    @Test func caretPastACappedFieldStaysInsideTheField() throws {
        let (scrollView, row, textView) = field(text: String(repeating: "a long note line\n", count: 40))
        // The field has not scrolled to its caret, which sits far below it.
        #expect(textView.caretRect(for: textView.endOfDocument).minY > textView.bounds.maxY)
        let (target, rect) = try #require(AppDelegate.caretScrollTarget(for: textView))
        #expect(target === scrollView)
        #expect(rect.maxY <= row.frame.maxY + 12)
    }

    @Test func fieldOutsideAScrollViewIsIgnored() {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        textView.text = "Lunch"
        textView.selectedTextRange = textView.textRange(from: textView.endOfDocument, to: textView.endOfDocument)
        #expect(AppDelegate.caretScrollTarget(for: textView) == nil)
    }
}
