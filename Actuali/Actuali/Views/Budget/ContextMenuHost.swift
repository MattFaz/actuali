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

/// Hosts SwiftUI content with a native UIKit context-menu interaction, so a
/// long-press lifts and zooms the whole content like any other context menu.
/// SwiftUI's `.contextMenu` doesn't present from a `List` section header,
/// which is where the Compact group rows live and must stay pinned.
struct ContextMenuHost<Content: View>: UIViewControllerRepresentable {
    let actions: [ContextMenuHostAction]
    let onTap: () -> Void
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Measures the content at its ideal height: flexible views such as a
    /// `Color.clear` spacer would otherwise stretch to the unbounded height
    /// offered while sizing.
    struct Sized: View {
        let content: Content

        var body: some View {
            content.fixedSize(horizontal: false, vertical: true)
        }
    }

    func makeUIViewController(context: Context) -> UIHostingController<Sized> {
        let controller = UIHostingController(rootView: Sized(content: content))
        controller.view.backgroundColor = .clear
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        controller.view.addInteraction(interaction)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        controller.view.addGestureRecognizer(tap)
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<Sized>, context: Context) {
        controller.rootView = Sized(content: content)
        context.coordinator.actions = actions
        context.coordinator.onTap = onTap
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<Sized>, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiViewController.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var actions: [ContextMenuHostAction] = []
        var onTap: () -> Void = {}

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
            preview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            preview(for: interaction)
        }

        private func preview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let view = interaction.view else { return nil }
            let parameters = UIPreviewParameters()
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: 14)
            return UITargetedPreview(view: view, parameters: parameters)
        }
    }
}
