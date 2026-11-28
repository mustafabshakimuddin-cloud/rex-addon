import SwiftUI

/// iPhone Duo's fold, read from SwiftUI's reserved regions (iOS 27.1). The `.division` region is
/// the crease; it is active only while the phone is partly open. Regions are read on every layout
/// pass and never cached, because the first reads after launch come back empty.
struct FoldObserver: ViewModifier {
    @Binding var fold: CGRect?

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let crease = Self.horizontalCrease(proxy)
                Color.clear
                    .onAppear { fold = crease }
                    .onChange(of: crease) { _, new in fold = new }
            }
            .ignoresSafeArea()
        }
    }

    /// The crease when it runs across the screen: the phone stands half-open like a small laptop,
    /// so the picture belongs above it and the controls below. A crease running top to bottom
    /// (held like a book) is left alone; video across it reads like on any foldable.
    static func horizontalCrease(_ proxy: GeometryProxy) -> CGRect? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 27.1, *) {
            guard let region = proxy.reservedRegions(kind: .division).first(where: \.isActive) else { return nil }
            let frame = region.frame
            guard frame.width > frame.height, frame.minY > 160 else { return nil }
            return frame
        }
        #endif
        return nil
    }
}

extension View {
    func foldObserver(_ fold: Binding<CGRect?>) -> some View {
        modifier(FoldObserver(fold: fold))
    }
}
