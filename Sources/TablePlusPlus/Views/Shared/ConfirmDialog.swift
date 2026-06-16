import SwiftUI

struct ConfirmDialog: View {
    let title: String
    let message: String
    let confirmLabel: String
    let cancelLabel: String
    let destructive: Bool
    var onConfirm: () -> Void
    var onCancel: () -> Void

    init(title: String,
         message: String,
         confirmLabel: String,
         cancelLabel: String = L10n.t("form.cancel"),
         destructive: Bool = false,
         onConfirm: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.destructive = destructive
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 12) {
            AppIcon(size: 56, withShadow: true)
                .padding(.top, 14)

            Text(title)
                .font(.system(size: 14, weight: .semibold))

            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text(cancelLabel).frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(width: 110)

                Button(action: onConfirm) {
                    Text(confirmLabel)
                        .foregroundStyle(destructive ? .red : .primary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(width: 110)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 280)
    }
}
