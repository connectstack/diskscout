import SwiftUI

struct ToastView: View {
    @EnvironmentObject var model: AppModel
    let toast: Toast

    private var color: Color {
        switch toast.style {
        case .success: return SafetyLevel.safe.color
        case .info: return Color.accentColor
        case .error: return SafetyLevel.protected.color
        }
    }

    private var icon: String {
        switch toast.style {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .symbolEffect(.bounce, value: toast.id)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.system(size: 12.5, weight: .semibold))
                if let d = toast.detail {
                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
            }
            if let batch = toast.undoBatch {
                Button("Undo") { model.undo(batch: batch); model.dismissToast() }
                    .buttonStyle(PillButtonStyle(color: .accentColor, prominent: false))
                    .keyboardShortcut("z", modifiers: .command)
            }
            Button { model.dismissToast() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.3)))
        .frame(maxWidth: 520)
        .padding(.bottom, 44)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
