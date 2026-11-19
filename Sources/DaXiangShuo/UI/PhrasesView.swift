import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PhrasesView: View {
    let phrases: PhraseStore
    @State private var kind: PhraseKind = .hotword
    @State private var term = ""
    @State private var value = ""
    @State private var editing: Phrase?
    @State private var alert: String?

    private var info: String {
        kind == .hotword
            ? "热词会发给语音识别提高命中率，同时作为专有名词表发给大模型。热词总长约 100 字，靠前的优先。"
            : "说出左边的内容，写入输入框时替换成右边的文字，比如「我的邮箱」替换成实际的邮箱地址。"
    }

    var body: some View {
        Page {
            SectionTitle(text: "类型") {
                Button("导入…", action: importJSON).buttonStyle(.soft)
                Button("导出…", action: exportJSON).buttonStyle(.soft)
            }
            SegmentedTabs(options: PhraseKind.allCases.map { ($0, $0.title) }, selection: $kind)

            SectionTitle("添加\(kind.title)", info: info)
            Card {
                HStack(spacing: 8) {
                    TextField(kind == .hotword ? "热词，例如：大象说" : "说出的内容", text: $term)
                        .fieldStyle()
                        .onSubmit(add)
                    if kind == .replacement {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(Theme.tertiary)
                        TextField("替换为", text: $value)
                            .fieldStyle()
                            .onSubmit(add)
                    }
                    Button("添加", action: add)
                        .buttonStyle(.soft)
                        .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            let list = phrases.items(of: kind)
            SectionTitle("已添加 \(list.count) 条")
            // 页面本身固定不滚动；词条很多时只在这块列表区域内部滚动，上面的添加区始终可见。
            ScrollView {
                Card {
                    if list.isEmpty {
                        Text("还没有\(kind.title)")
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, phrase in
                            if index > 0 { CardDivider() }
                            HStack(spacing: 10) {
                                Text(phrase.trigger).foregroundStyle(Theme.text)
                                if phrase.kind == .replacement {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 12, weight: .light))
                                        .foregroundStyle(Theme.tertiary)
                                    Text(phrase.value).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                                Spacer()
                                IconButton(systemName: "pencil", help: "编辑") { editing = phrase }
                                IconButton(systemName: "trash", help: "删除") { phrases.delete(phrase) }
                            }
                            .font(Theme.font)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .sheet(item: $editing) { phrase in
            PhraseEditor(phrase: phrase) { phrases.update($0) }
        }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好") { alert = nil }
        }
    }

    private func add() {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        phrases.add(kind: kind, trigger: trimmed, value: kind == .replacement ? value : "")
        term = ""
        value = ""
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try phrases.importJSON(try Data(contentsOf: url))
            alert = "已导入 \(count) 条"
        } catch {
            alert = "导入失败：\(error.localizedDescription)"
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "大象说词典.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try phrases.exportJSON().write(to: url)
        } catch {
            alert = "导出失败：\(error.localizedDescription)"
        }
    }
}

private struct PhraseEditor: View {
    @State var phrase: Phrase
    let onSave: (Phrase) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑\(phrase.kind.title)").foregroundStyle(Theme.text)
            TextField(phrase.kind == .hotword ? "热词" : "说出的内容", text: $phrase.trigger)
                .fieldStyle()
            if phrase.kind == .replacement {
                TextField("替换为", text: $phrase.value)
                    .fieldStyle()
            }
            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.soft)
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(phrase)
                    dismiss()
                }
                .buttonStyle(.soft)
                .keyboardShortcut(.defaultAction)
                .disabled(phrase.trigger.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 6)
        }
        .font(Theme.font)
        .padding(20)
        .frame(width: 400)
        .background(Theme.background)
    }
}
