import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var trash: TrashManager

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(systemImage: "clock.arrow.circlepath", color: .accentColor, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleanup History").font(.system(size: 15, weight: .bold))
                    Text("Everything DiskScout moved to the Trash. Put items back as long as they're still in the Trash.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Freed in total").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    BytesText(bytes: trash.lifetimeFreed, font: .system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(SafetyLevel.safe.color)
                }
                Button("Clear") { trash.clearHistory() }.buttonStyle(.bordered).controlSize(.small).disabled(trash.history.isEmpty)
            }
            .padding(16)
            Divider()
            if trash.history.isEmpty {
                EmptyState(systemImage: "tray", title: "No history yet", message: "Items you move to the Trash with DiskScout will show up here.", tint: .secondary)
            } else {
                List {
                    ForEach(trash.history) { r in
                        HStack(spacing: 10) {
                            Image(systemName: r.restored ? "arrow.uturn.backward.circle.fill" : (r.trashedPath == nil ? "xmark.bin.fill" : "trash.fill"))
                                .foregroundStyle(r.restored ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(r.originalPath).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(DateFormat.relativeString(r.date)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(r.size.bytesString).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 76, alignment: .trailing)
                            if r.restored {
                                Text("Put back").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).frame(width: 70)
                            } else if r.trashedPath == nil {
                                Text("Emptied").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).frame(width: 70)
                            } else {
                                Button("Put Back") { model.putBack(r) }.buttonStyle(.bordered).controlSize(.small).frame(width: 70)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}
