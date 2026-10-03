import SwiftUI
import UIKit

/// One entry of a `ContextMenuHost` menu.
struct ContextMenuHostAction {
    let title: String
    let systemImage: String
    let handler: () -> Void
}

/// Hosts SwiftUI content with a native UIKit context-menu interaction, so a
/// long-press lifts and zooms the whole content like any other context menu.
/// SwiftUI's `.contextMenu` doesn't present from a `List` section header,
/// which is where the Compact group rows live and must stay pinned.
struct ContextMenuHost<Content: View>: UIViewControllerRepresentable {
    let actions: [ContextMenuHostAction]
    let cornerRadius: CGFloat
    let onTap: () -> Void
    let content: Content

    init(
        actions: [ContextMenuHostAction],
        cornerRadius: CGFloat = 14,
        onTap: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.actions = actions
        self.cornerRadius = cornerRadius
        self.onTap = onTap
        self.content = content()
    }

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
        context.coordinator.cornerRadius = cornerRadius
        context.coordinator.onTap = onTap
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<Sized>, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let size = uiViewController.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var actions: [ContextMenuHostAction] = []
        var cornerRadius: CGFloat = 14
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
            parameters.visiblePath = UIBezierPath(roundedRect: view.bounds, cornerRadius: cornerRadius)
            return UITargetedPreview(view: view, parameters: parameters)
        }
    }
}
