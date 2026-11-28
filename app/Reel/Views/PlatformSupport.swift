import SwiftUI
#if os(tvOS)
import CoreImage.CIFilterBuiltins
#endif

/// The few places where iPhone and iPad (touch) and Apple TV (focus and the Siri Remote) need
/// different building blocks. Screens use these instead of branching themselves.
enum DeviceStyle {
    #if os(tvOS)
    static let isTV = true
    /// The space at a screen's sides. tvOS already keeps content inside the TV's safe area; this
    /// is the gap between cards, which have to grow when focused.
    static let gutter: CGFloat = 50
    #else
    static let isTV = false
    static let gutter: CGFloat = 20
    #endif
}

extension View {
    /// A poster, card or row that opens something. Plain on a touch screen; on Apple TV the
    /// focused card lifts, as the Home Screen's do.
    func cardButton() -> some View {
        #if os(tvOS)
        buttonStyle(FocusCardStyle())
        #else
        buttonStyle(.plain)
        #endif
    }

    /// The compact navigation title of iPhone and iPad; Apple TV has one title style.
    @ViewBuilder func inlineNavigationTitle() -> some View {
        #if os(tvOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Actions at the trailing end of the navigation bar. Apple TV's navigation bar holds no
    /// buttons, so there they are a row above the screen, which focus reaches by moving up.
    func barActions<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        #if os(tvOS)
        safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 24) {
                Spacer(minLength: 0)
                content()
            }
            .padding(.bottom, 16)
            .focusSection()
        }
        #else
        toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) { content() }
        }
        #endif
    }
}

#if os(tvOS)
/// A focused card grows and casts a shadow; pressed, it sinks back a little.
struct FocusCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration)
    }

    private struct Card: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 1.02 : (focused ? 1.08 : 1))
                .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: focused ? 24 : 0, y: focused ? 16 : 0)
                .brightness(focused ? 0.06 : 0)
                .animation(.easeOut(duration: 0.18), value: focused)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}
#endif

/// A value picked on a range: a slider by touch, and on Apple TV (which has no sliders) a pair of
/// buttons that step it.
struct RangeControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// How the value reads next to the buttons on Apple TV.
    var format: (Double) -> String = { String(format: "%.1f", $0) }

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 20) {
            Button { value = max(range.lowerBound, (value - step).rounded(to: step)) } label: {
                Image(systemName: "minus")
            }
            .disabled(value <= range.lowerBound)
            Text(format(value)).monospacedDigit().frame(minWidth: 120)
            Button { value = min(range.upperBound, (value + step).rounded(to: step)) } label: {
                Image(systemName: "plus")
            }
            .disabled(value >= range.upperBound)
        }
        #else
        Slider(value: $value, in: range, step: step)
        #endif
    }
}

private extension Double {
    /// Snapped to the nearest multiple of `step`, so repeated steps don't drift (0.1 + 0.2 …).
    func rounded(to step: Double) -> Double { (self / step).rounded() * step }
}

/// A link someone may want on their phone. Shared through the share sheet on iPhone and iPad; on
/// Apple TV, which has neither a share sheet nor a browser, shown as a QR code to scan.
struct ShareLinkButton: View {
    let url: URL
    var title: String = "Share"
    var subject: String?

    #if os(tvOS)
    @State private var showing = false
    #endif

    var body: some View {
        #if os(tvOS)
        Button { showing = true } label: { Label(title.localized, systemImage: "qrcode") }
            .sheet(isPresented: $showing) {
                QRCodeSheet(url: url, title: subject ?? title)
            }
        #else
        if let subject {
            ShareLink(item: url, subject: Text(subject)) { Label(title.localized, systemImage: "square.and.arrow.up") }
        } else {
            ShareLink(item: url) { Label(title.localized, systemImage: "square.and.arrow.up") }
        }
        #endif
    }
}

#if os(tvOS)
/// A link as a QR code, for the phone's camera.
struct QRCodeSheet: View {
    let url: URL
    let title: String

    var body: some View {
        VStack(spacing: 36) {
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            if let image = Self.code(for: url.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 420, height: 420)
                    .padding(24)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            Text("Scan with your phone's camera").foregroundStyle(Theme.secondaryText)
            Text(url.absoluteString).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
        }
        .padding(60)
    }

    static func code(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
#endif

extension View {
    /// Settings-style lists: inset and grouped on iPhone and iPad, grouped on Apple TV (which has
    /// no inset style).
    @ViewBuilder func groupedList() -> some View {
        #if os(tvOS)
        listStyle(.grouped)
        #else
        listStyle(.insetGrouped)
        #endif
    }

    /// Lets the screen's backdrop show through a List or Form. Apple TV's lists are already clear.
    @ViewBuilder func clearListBackground() -> some View {
        #if os(tvOS)
        self
        #else
        scrollContentBackground(.hidden)
        #endif
    }

    /// The large spinner and controls of iPhone and iPad; Apple TV's are large to begin with.
    @ViewBuilder func largeControl() -> some View {
        #if os(tvOS)
        self
        #else
        controlSize(.large)
        #endif
    }
}

extension View {
    /// A spinner smaller than the default, where a row has room for only a little one.
    @ViewBuilder func smallControl(_ size: ControlSizeChoice = .small) -> some View {
        #if os(tvOS)
        scaleEffect(size == .mini ? 0.5 : 0.7)
        #else
        controlSize(size == .mini ? .mini : .small)
        #endif
    }
}

enum ControlSizeChoice { case small, mini }
