import SwiftUI

struct ErrorDialog: View {
    var title: String = L10n.t("error.statement")
    var message: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppIcon(size: 72, withShadow: true)
                .padding(.top, 18)

            Text(title)
                .font(.system(size: 16, weight: .semibold))

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)

            Button(L10n.t("error.ok"), action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.defaultAction)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(width: 360)
        .padding(8)
    }
}
