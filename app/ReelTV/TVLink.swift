import SwiftUI

/// Apple TV has no browser, so a link here opens as a QR code to scan with a phone. Declared in
/// the app's own module, this takes the place of SwiftUI's `Link` for every screen in the tvOS
/// build; the iPhone build keeps the system one.
struct Link<Content: View>: View {
    let destination: URL
    let content: Content
    @State private var showing = false

    init(destination: URL, @ViewBuilder label: () -> Content) {
        self.destination = destination
        content = label()
    }

    var body: some View {
        Button { showing = true } label: { content }
            .sheet(isPresented: $showing) {
                QRCodeSheet(url: destination, title: destination.host() ?? destination.absoluteString)
            }
    }
}
