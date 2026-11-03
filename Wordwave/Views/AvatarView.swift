import AppKit
import SwiftUI

/// Circular profile picture, with coloured initials as fallback.
struct AvatarView: View {
    let path: String?
    let name: String

    var body: some View {
        Group {
            if let image = AvatarCache.image(at: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(fallbackColor.gradient)
                    if let initials {
                        Text(initials)
                            .font(.system(size: 15, weight: .semibold))
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 17))
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .clipShape(Circle())
    }

    private var initials: String? {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first(where: \.isLetter) }
        return letters.isEmpty ? nil : String(letters).uppercased()
    }

    /// Stable across launches (unlike `hashValue`).
    private var fallbackColor: Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .mint]
        let hash = name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[Int(hash.magnitude % UInt(palette.count))]
    }
}

@MainActor
private enum AvatarCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at path: String?) -> NSImage? {
        guard let path else { return nil }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
