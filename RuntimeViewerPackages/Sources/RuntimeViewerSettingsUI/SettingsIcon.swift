import SwiftUI
import SwiftUIIntrospect

struct SettingsIcon: View {
    private let content: IconContent
    private let color: Color?
    private let size: CGFloat

    init(
        symbol: String,
        color: Color? = nil,
        size: CGFloat? = nil
    ) {
        self.content = .symbol(symbol)
        self.color = color ?? .accentColor
        self.size = size ?? 20
    }

    init(
        text: String,
        textColor: Color? = nil,
        color: Color? = nil,
        size: CGFloat? = nil
    ) {
        self.content = .text(text, textColor: textColor)
        self.color = color ?? .accentColor
        self.size = size ?? 20
    }

    init(
        image: Image,
        size: CGFloat? = nil
    ) {
        self.content = .image(image)
        self.color = nil
        self.size = size ?? 20
    }

    private func getSafeImage(named: String) -> Image {
        if NSImage(systemSymbolName: named, accessibilityDescription: nil) != nil {
            return Image(systemName: named)
        } else {
            return Image(named)
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(background)
            .overlay {
                switch content {
                case .symbol(let name):
                    getSafeImage(named: name)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(.white)
                        .padding(size / 8)
                case .text(let text, let textColor):
                    Text(text)
                        .font(.system(size: size * 0.65))
                        .foregroundColor(textColor ?? .primary)
                case .image(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .shadow(
                color: Color(NSColor.black).opacity(0.25),
                radius: size / 40,
                y: size / 40
            )
            .frame(width: size, height: size)
    }

    private var background: AnyShapeStyle {
        switch content {
        case .symbol,
             .text:
            return AnyShapeStyle((color ?? .accentColor).gradient)
        case .image:
            return AnyShapeStyle(.regularMaterial)
        }
    }

    private enum IconContent {
        case symbol(String)
        case text(String, textColor: Color?)
        case image(Image)
    }
}
