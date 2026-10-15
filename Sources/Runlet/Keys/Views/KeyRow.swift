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
            if entry.hasExpiry {
                ttlBadge
            }
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

    /// Expiry badge, tinted by urgency: red under an hour, orange under a
    /// day, neutral beyond. Keys without expiry get no badge, so expiring
    /// keys stand out.
    private var ttlBadge: some View {
        Text(entry.ttlText)
            .font(.caption2.weight(.medium))
            .foregroundStyle(isSelected ? AppColor.onSelectionSecondary : ttlBadgeColor)
            .lineLimit(1)
            .padding(.horizontal, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.xxSmall)
            .frame(minWidth: AppSize.typeBadgeWidth, alignment: .center)
            .background(isSelected ? AppColor.selectionBadgeBackground : AppColor.subtleBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
            .help(entry.ttl == -2 ? "Expired" : "Expires in \(entry.ttlText)")
    }

    private var ttlBadgeColor: Color {
        guard let ttl = entry.ttl, ttl > 0 else { return .secondary }
        if ttl < 3600 {
            return AppColor.error
        }
        if ttl < 86_400 {
            return AppColor.warning
        }
        return .secondary
    }
}
