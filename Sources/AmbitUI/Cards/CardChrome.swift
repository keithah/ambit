import SwiftUI

extension View {
    func cardChrome(cornerRadius: CGFloat = 8) -> some View {
        self
            .padding(10)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Theme.cardStroke, lineWidth: 1)
            )
    }
}
