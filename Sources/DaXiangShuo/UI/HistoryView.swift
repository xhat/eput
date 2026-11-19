import AppKit
import SwiftUI

struct HistoryView: View {
    @Bindable var history: HistoryStore
    @State private var confirmClear = false

    var body: some View {
        Page(scrolls: true) {
            SectionTitle(text: "共 \(history.items.count) 条", info: "每次听写的最终文字。右键某一条可以复制识别原文或删除。") {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .light))
                        .foregroundStyle(Theme.tertiary)
                    TextField("搜索", text: $history.search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(width: 220, height: Theme.controlHeight)
                .background(Theme.controlShape().fill(Theme.control))
                .overlay(Theme.controlShape().strokeBorder(Theme.border, lineWidth: Theme.hairline))
                Button("清空") { confirmClear = true }
                    .buttonStyle(.softDestructive)
                    .disabled(history.items.isEmpty)
            }

            Card {
                if history.items.isEmpty {
                    Text(history.search.isEmpty ? "暂无记录" : "没有匹配的记录")
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(history.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { CardDivider() }
                            HistoryRow(item: item) { history.delete(item) }
                        }
                    }
                }
            }
        }
        .confirmationDialog("确定清空全部历史记录吗？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { history.clear() }
        }
        .onAppear { history.reload() }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .foregroundStyle(Theme.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(item.created, format: .dateTime.month().day().hour().minute())
                    if !item.app.isEmpty { Text(item.app) }
                    Text(String(format: "%.1f 秒", item.duration))
                }
                .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 8)
            IconButton(systemName: "doc.on.doc", help: "复制") { copy(item.text) }
        }
        .font(Theme.font)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button("复制") { copy(item.text) }
            if item.raw != item.text { Button("复制识别原文") { copy(item.raw) } }
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
