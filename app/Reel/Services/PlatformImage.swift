import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
import SwiftUI

// The Mac has no UIKit. The app works with UIImage throughout (decoded posters, logos, widget
// pictures, now-playing artwork), so on the Mac that name is AppKit's NSImage, with the two
// UIKit conveniences the app uses.

typealias UIImage = NSImage

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}
#endif
