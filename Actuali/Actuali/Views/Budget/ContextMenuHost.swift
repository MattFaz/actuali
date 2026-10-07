import SwiftUI
import UIKit

/// One group-header action, shared by the Clean and Compact menus.
struct ContextMenuHostAction {
    let title: String
    let systemImage: String
    let handler: () -> Void

    static func groupActions(
        isHidden: Bool,
        onApplyTemplate: (() -> Void)? = nil,
        onOverwriteTemplate: (() -> Void)? = nil,
        onRename: (() -> Void)?,
        onSetHidden: ((Bool) -> Void)?,
        locale: Locale
    ) -> [Self] {
        var items: [Self] = []
        if let onApplyTemplate {
            items.append(.init(
                title: ReportStrings.text("Apply Budget Template", locale: locale, bundle: .main),
                systemImage: "wand.and.stars", handler: onApplyTemplate
            ))
        }
        if let onOverwriteTemplate {
            items.append(.init(
                title: ReportStrings.text("Overwrite with Budget Template", locale: locale, bundle: .main),
                systemImage: "wand.and.stars.inverse", handler: onOverwriteTemplate
            ))
        }
        if let onRename {
            items.append(.init(
                title: String(localized: "Rename Group", bundle: .main, locale: locale),
                systemImage: "pencil", handler: onRename
            ))
        }
        if let onSetHidden {
            items.append(.init(
                title: ReportStrings.text(isHidden ? "Show Group" : "Hide Group", locale: locale, bundle: .main),
                systemImage: isHidden ? "eye" : "eye.slash",
                handler: { onSetHidden(!isHidden) }
            ))
        }
        return items
    }
}

/// A transparent UIKit overlay that adds a native context-menu interaction
/// and a tap to the SwiftUI content beneath it, so a long-press lifts the
/// whole row like any other context menu. SwiftUI's `.contextMenu` doesn't
/// present from a `List` section header, which is where the Compact group
/// rows live and must stay pinned.
///
/// The content stays in the List's own SwiftUI graph rather than inside a
/// nested `UIHostingController`: hosting each pinned header separately meant
/// a fresh hosting controller and a synchronous nested layout per header on
/// every scroll pass, which made Compact scrolling stutter.
struct ContextMenuHost: UIViewRepresentable {
    let actions: [ContextMenuHostAction]
    let onTap: () -> Void
    /// The lift preview is a snapshot, so UIKit can't hide the real row the
    /// way it hides a source view it owns; the row hides itself while lifted.
    let onLift: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.onTap = onTap
        context.coordinator.onLift = onLift
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var actions: [ContextMenuHostAction] = []
        var onTap: () -> Void = {}
        var onLift: (Bool) -> Void = { _ in }
        private var preview: UITargetedPreview?

        @objc func tapped() {
            onTap()
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard !actions.isEmpty else { return nil }
            let items = actions
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: items.map { item in
                    UIAction(title: item.title, image: UIImage(systemName: item.systemImage)) { _ in
                        item.handler()
                    }
                })
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            // The overlay itself draws nothing, so lift a snapshot of the row
            // beneath it. Taken once here and reused on dismissal, when the
            // window would also contain the menu.
            guard let view = interaction.view, let window = view.window,
                  let snapshot = window.resizableSnapshotView(
                      from: view.convert(view.bounds, to: window),
                      afterScreenUpdates: false,
                      withCapInsets: .zero
                  )
            else { return nil }
            let parameters = UIPreviewParameters()
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 14)
            let preview = UITargetedPreview(
                view: snapshot,
                parameters: parameters,
                target: UIPreviewTarget(container: view, center: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            )
            self.preview = preview
            return preview
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            defer { preview = nil }
            return preview
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willDisplayMenuFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            onLift(true)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            guard let animator else { return onLift(false) }
            animator.addCompletion { self.onLift(false) }
        }
    }
}
