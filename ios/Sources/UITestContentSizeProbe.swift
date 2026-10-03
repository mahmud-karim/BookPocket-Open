#if DEBUG
import SwiftUI
import UIKit

/// Observes both frameworks' real content-size settings. It never overrides them.
struct UITestContentSizeProbe: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    func makeUIView(context: Context) -> ContentSizeProbeView { ContentSizeProbeView(frame: .zero) }
    func updateUIView(_ view: ContentSizeProbeView, context: Context) {
        view.swiftUISize = String(describing: dynamicTypeSize)
        view.refresh()
    }
}

final class ContentSizeProbeView: UIView {
    var swiftUISize = "unknown"
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "test.content-size"
        accessibilityLabel = "Actual content size"
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    override func didMoveToWindow() { super.didMoveToWindow(); refresh() }
    override func layoutSubviews() { super.layoutSubviews(); refresh() }
    func refresh() {
        accessibilityValue = "UIKit=\(traitCollection.preferredContentSizeCategory.rawValue); SwiftUI=\(swiftUISize)"
    }
}
#endif
