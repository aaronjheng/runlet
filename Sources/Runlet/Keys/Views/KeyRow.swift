import SwiftUI

struct KeyRow: View {
    let entry: RedisKeyEntry
    var displayName: String?
    @Environment(\.listRowIsSelected) private var isSelected

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Text(redisKeyTypeTitle(entry.type))
                .font(.caption2.weight(.medium))
                .foregroundStyle(isSelected ? AppColor.onSelectionSecondary : .secondary)
                .lineLimit(1)
                .frame(width: AppSize.typeBadgeWidth, alignment: .center)
                .padding(.vertical, AppSpacing.xxSmall)
                .background(isSelected ? AppColor.selectionBadgeBackground : AppColor.subtleBackground)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
            Text(displayName ?? entry.key)
                .font(.body)
                .foregroundStyle(isSelected ? AppColor.onSelection : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, AppSpacing.medium)
        .padding(.leading, AppSpacing.small)
        .padding(.trailing, AppSpacing.small)
        .contentShape(Rectangle())
        .help(entry.key)
        .accessibilityLabel(entry.key)
    }
}
