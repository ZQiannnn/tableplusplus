import SwiftUI

struct AppIcon: View {
    var size: CGFloat = 64
    var cornerRatio: CGFloat = 0.225
    var glyphRatio: CGFloat = 0.50
    var withShadow: Bool = true

    var body: some View {
        RoundedRectangle(cornerRadius: size * cornerRatio, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.97, green: 0.55, blue: 0.07), // 橙
                        Color(red: 0.00, green: 0.46, blue: 0.56), // 青绿
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: "cylinder.fill")
                    .font(.system(size: size * glyphRatio, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(
                color: withShadow ? Color.black.opacity(0.25) : .clear,
                radius: withShadow ? size * 0.12 : 0,
                y: withShadow ? size * 0.05 : 0
            )
    }
}
