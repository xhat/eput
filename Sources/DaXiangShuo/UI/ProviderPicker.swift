import SwiftUI

/// 一个渠道选项：品牌色 + 图标 + 名称 + 一句话说明。
struct ProviderOption<Value: Hashable> {
    let value: Value
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
}

/// 渠道切换控件：两张并列的卡片，选中的那张用品牌色描边 + 浅色底 + 勾选标记。
/// 比下拉菜单更显眼，一眼能看出现在是哪个渠道、另一个渠道是什么。
struct ProviderPicker<Value: Hashable>: View {
    let options: [ProviderOption<Value>]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.value) { option in
                ProviderCard(option: option, selected: selection == option.value) {
                    withAnimation(.easeOut(duration: 0.16)) { selection = option.value }
                }
            }
        }
    }
}

private struct ProviderCard<Value: Hashable>: View {
    let option: ProviderOption<Value>
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .circular)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .circular)
                        .fill(selected
                              ? AnyShapeStyle(LinearGradient(colors: [option.tint, option.tint.opacity(0.72)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(option.tint.opacity(0.14)))
                    Image(systemName: option.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : option.tint)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(option.subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(selected ? option.tint : Theme.tertiary.opacity(0.45))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 56)
            .background(
                shape.fill(selected ? option.tint.opacity(0.08)
                                    : (hovering ? Theme.controlHover : Theme.card))
                    .shadow(color: selected ? option.tint.opacity(0.18) : Theme.controlShadow,
                            radius: selected ? 3 : 1.2, y: selected ? 1 : 0.5)
            )
            .overlay(
                shape.strokeBorder(selected ? option.tint.opacity(0.6) : Theme.border.opacity(0.7),
                                   lineWidth: selected ? 1 : Theme.hairline)
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && !selected }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 参数卡片顶部的一条「当前渠道」说明，用品牌色的小圆点和名称把上下两块连起来。
struct ChannelHeader: View {
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
            Text(detail)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}
