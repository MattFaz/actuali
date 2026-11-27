import UIKit

/// The amount field's keyboard, laid out like a calculator (and like YNAB's):
///
///     1  2  3   ÷  ⌫
///     4  5  6   ×  ±
///     7  8  9   −  Done
///     .  0  00  +
///
/// The system decimal pad can't carry operator or Done keys, and a bar of
/// them floating above it read as a second keyboard. ± only shows where the
/// field has a sign to flip; without it Done takes its row as well.
///
/// The keypad only reports keys; the field's coordinator applies them, so the
/// entry logic (cent shifting, replacing a selected amount) stays in one place.
final class AmountKeypadView: UIInputView, UIInputViewAudioFeedback {
    private var decimalKey: UIButton?
    private var signKey: UIButton?

    /// Follows the budget's number format, so the key matches what the
    /// field shows. The field accepts either separator.
    var decimalSeparator: String {
        didSet { decimalKey?.configuration?.title = decimalSeparator }
    }

    /// Follows the caller's own sign control, so ± can't sit live while the
    /// button beside the field refuses to flip.
    var isSignEnabled = true {
        didSet { signKey?.isEnabled = isSignEnabled }
    }

    var enableInputClicksWhenVisible: Bool {
        true
    }

    /// `onType` gets one character, or "" for delete.
    init(
        decimalSeparator: String,
        onType: @escaping @MainActor (String) -> Void,
        onOperator: @escaping @MainActor (AmountInputField.Coordinator.Operator) -> Void,
        onToggleSign: (@MainActor () -> Void)?,
        onDone: @escaping @MainActor () -> Void
    ) {
        self.decimalSeparator = decimalSeparator
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 240), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        accessibilityIdentifier = "amountKeypad"

        func type(_ text: String) -> Key {
            Key(title: text, label: text, style: .digit, typesText: true) {
                // 00 is two keystrokes: one replacement string longer than a
                // character reads as a paste.
                for character in text {
                    onType(String(character))
                }
            }
        }
        let decimal = Key(title: decimalSeparator, label: decimalSeparator, style: .digit, typesText: true) {
            onType(".")
        }
        let operators: [AmountInputField.Coordinator.Operator] = [.divide, .multiply, .subtract, .add]
        let columns: [[Key]] = [
            [type("1"), type("4"), type("7"), decimal],
            [type("2"), type("5"), type("8"), type("0")],
            [type("3"), type("6"), type("9"), type("00")],
            operators.map { op in
                Key(symbol: op.symbolName, label: op.accessibilityLabel, style: .function) { onOperator(op) }
            },
        ]
        let delete = Key(symbol: "delete.left", label: String(localized: "Delete"), style: .function, typesText: true) {
            onType("")
        }
        let sign = onToggleSign.map {
            Key(symbol: "plus.forwardslash.minus", label: String(localized: "Flip sign"), style: .function, action: $0)
        }
        let done = Key(title: String(localized: "Done"), label: String(localized: "Done"), style: .done, action: onDone)

        let spacing: CGFloat = 6
        let columnStacks = columns.map { keys in
            let stack = UIStackView(arrangedSubviews: keys.map(\.button))
            stack.axis = .vertical
            stack.spacing = spacing
            stack.distribution = .fillEqually
            return stack
        }
        // Done fills whatever rows delete and ± leave it.
        let fixedKeys = [delete.button] + (sign.map { [$0.button] } ?? [])
        let lastColumn = UIStackView(arrangedSubviews: fixedKeys + [done.button])
        lastColumn.axis = .vertical
        lastColumn.spacing = spacing
        let keys = UIStackView(arrangedSubviews: columnStacks + [lastColumn])
        keys.spacing = spacing
        keys.distribution = .fillEqually
        keys.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keys)

        decimalKey = decimal.button
        signKey = sign?.button
        let firstKey = columns[0][0].button
        // Full width on a phone, but an iPad keyboard spans the screen and
        // keys that wide stop reading as a keypad, so the grid caps out.
        let fullWidth = keys.widthAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor, constant: -2 * spacing)
        fullWidth.priority = .defaultHigh
        // Self-sizing reads the keypad's height from the keys, but while it
        // animates in, the system pins it to the initial frame's height;
        // just under required lets the keys give way then instead of
        // logging a constraint conflict.
        let keyHeight = firstKey.heightAnchor.constraint(equalToConstant: 50)
        keyHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate(fixedKeys.map { $0.heightAnchor.constraint(equalTo: firstKey.heightAnchor) } + [
            keyHeight,
            keys.topAnchor.constraint(equalTo: topAnchor, constant: spacing),
            keys.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -spacing),
            keys.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            keys.widthAnchor.constraint(lessThanOrEqualToConstant: 540),
            fullWidth,
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// One keypad key. Digits read like the system keypad's keys; operators
    /// and delete sit on the darker function-key fill; Done takes the accent.
    @MainActor
    private struct Key {
        enum Style {
            case digit, function, done
        }

        let button: UIButton

        /// `typesText` marks keys that edit the text (digits, delete) as
        /// keyboard keys for VoiceOver; the rest are ordinary buttons.
        init(
            title: String? = nil,
            symbol: String? = nil,
            label: String,
            style: Style,
            typesText: Bool = false,
            action: @escaping @MainActor () -> Void
        ) {
            var configuration = UIButton.Configuration.filled()
            configuration.title = title
            configuration.image = symbol.map { UIImage(systemName: $0) } ?? nil
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .title3)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .preferredFont(forTextStyle: style == .done ? .headline : .title2)
                return attributes
            }
            configuration.cornerStyle = .fixed
            configuration.background.cornerRadius = 10
            // Opaque fills: the keyboard backdrop is translucent, and a
            // see-through key shows the tab bar hidden behind it.
            switch style {
            case .digit:
                configuration.baseBackgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.38, alpha: 1) : .white }
                configuration.baseForegroundColor = .label
            case .function:
                configuration.baseBackgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1) : UIColor(white: 0.78, alpha: 1) }
                configuration.baseForegroundColor = .label
            case .done:
                configuration.baseBackgroundColor = UIColor(named: "AccentColor")
                configuration.baseForegroundColor = .white
            }
            button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
                UIDevice.current.playInputClick()
                action()
            })
            button.accessibilityLabel = label
            if typesText {
                button.accessibilityTraits = .keyboardKey
            }
        }
    }
}
