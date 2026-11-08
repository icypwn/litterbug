import SwiftUI

struct PageTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.custom("CheeseMilky", size: 30))
            .foregroundStyle(.white)
    }
}

struct PlaceholderPage: View {
    let title: String

    var body: some View {
        PageTitle(title)
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.appBackground)
    }
}
