import SwiftUI

struct SettingsForm<Content: View>: View {
    @ViewBuilder
    var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
    }
}
