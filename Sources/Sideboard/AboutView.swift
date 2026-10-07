import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            AppIconImage(size: 88)
            Text(verbatim: "Sideboard")
                .font(.title.weight(.semibold))
            Text("Version \(AppLinks.version)")
                .foregroundStyle(.secondary)
            Text("Sideboard is free and open source (MIT License).")
                .multilineTextAlignment(.center)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent {
                    Link(AppLinks.contactEmail, destination: URL(string: "mailto:\(AppLinks.contactEmail)")!)
                } label: {
                    Text("Contact")
                }
                if let repository = AppLinks.repository {
                    Link(destination: repository) {
                        Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                if let support = AppLinks.support {
                    Text("If Sideboard makes looking after your devices easier, you can buy the developer a coffee.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: support) {
                        Label("Support Sideboard", systemImage: "heart")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 400)
    }
}
