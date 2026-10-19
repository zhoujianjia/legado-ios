import SwiftUI
import UIKit

/// Measures the reader surface itself. A split-view or Stage Manager window can
/// be tall while the device interface orientation is landscape, so orientation
/// notifications cannot tell the renderer its available width and height.
struct ReaderViewportSizeObserver: UIViewRepresentable {
    let onSizeChange: (CGSize) -> Void

    func makeUIView(context: Context) -> MeasuringView {
        MeasuringView(onSizeChange: onSizeChange)
    }

    func updateUIView(_ view: MeasuringView, context: Context) {
        // A delivery may already be queued when SwiftUI updates this closure.
        // Read the current closure at delivery instead of capturing an old view.
        view.onSizeChange = onSizeChange
    }

    static func dismantleUIView(_ view: MeasuringView, coordinator: ()) {
        view.invalidate()
    }

    @MainActor
    final class MeasuringView: UIView {
        var onSizeChange: ((CGSize) -> Void)?
        private(set) var pendingDelivery: Task<Void, Never>?
        private var lastReportedSize: CGSize?
        private var isInvalidated = false

        init(onSizeChange: @escaping (CGSize) -> Void) {
            self.onSizeChange = onSizeChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleSizeDelivery()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                cancelPendingDelivery()
                lastReportedSize = nil
                return
            }
            scheduleSizeDelivery()
        }

        func invalidate() {
            isInvalidated = true
            cancelPendingDelivery()
            onSizeChange = nil
        }

        private func cancelPendingDelivery() {
            pendingDelivery?.cancel()
            pendingDelivery = nil
        }

        private func scheduleSizeDelivery() {
            guard !isInvalidated, window != nil,
                  Self.isValid(bounds.size), bounds.size != lastReportedSize,
                  pendingDelivery == nil else { return }

            // A UIKit layout can run inside SwiftUI's update. Defer this actual
            // layout signal to the main actor's next turn; no timer or guessed
            // rotation size is needed. Multiple layouts share one delivery,
            // which reads the final live bounds rather than an earlier snapshot.
            pendingDelivery = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.pendingDelivery = nil
                guard !self.isInvalidated, self.window != nil else { return }
                let size = self.bounds.size
                guard Self.isValid(size), size != self.lastReportedSize else { return }
                self.lastReportedSize = size
                self.onSizeChange?(size)
            }
        }

        private static func isValid(_ size: CGSize) -> Bool {
            size.width.isFinite && size.height.isFinite
                && size.width > 1 && size.height > 1
        }
    }
}

#Preview {
    Color.clear
        .background(ReaderViewportSizeObserver { _ in })
}
