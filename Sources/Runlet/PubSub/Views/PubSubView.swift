import SwiftUI

// MARK: - Pub/Sub View

/// Pub/Sub panel modelled on RedisInsight's PubSub page: a subscription bar
/// (channel/pattern topics), a live message list, and a publish form pinned to
/// the bottom. Subscriptions run on a dedicated connection owned by `TabState`.
struct PubSubView: View {
    @Environment(TabState.self) private var tab

    @State private var topicInput = ""
    @State private var mode: PubSubSubscriptionMode = .pattern
    @State private var filterText = ""
    @State private var autoScroll = true
    @State private var selectedEntryID: PubSubEntry.ID?

    @State private var publishChannel = ""
    @State private var publishMessage = ""
    @State private var publishFeedback: String?
    @State private var publishFeedbackTask: Task<Void, Never>?
    @State private var isPublishing = false

    private var isSubscribed: Bool { tab.isPubSubSubscribed }
    private var isBusy: Bool { tab.isPubSubSubscribed || tab.isPubSubSubscribing }

    private var hasMessages: Bool { !tab.pubSubEntries.isEmpty }

    private var subscribedTopicsText: String {
        tab.pubSubSubscriptions.map(\.topic).joined(separator: " ")
    }

    private var filteredEntries: [PubSubEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return tab.pubSubEntries }
        return tab.pubSubEntries.filter { $0.searchText.contains(query) }
    }

    private var selectedEntry: PubSubEntry? {
        guard let selectedEntryID else { return nil }
        return filteredEntries.first { $0.id == selectedEntryID }
    }

    var body: some View {
        let filtered = filteredEntries
        VStack(spacing: 0) {
            SubscriptionBarView(
                topicInput: $topicInput,
                mode: $mode,
                isSubscribed: isSubscribed,
                isSubscribing: tab.isPubSubSubscribing,
                hasMessages: hasMessages,
                topicsText: subscribedTopicsText,
                onToggleSubscription: toggleSubscription,
                onClearMessages: clearMessages
            )

            MessagesBarView(
                filterText: $filterText,
                autoScroll: $autoScroll,
                messageCount: tab.pubSubEntries.count
            )

            if let error = tab.pubSubError {
                ErrorBanner(message: error, severity: .warning, dismissAction: { tab.pubSubError = nil })
            }

            if filtered.isEmpty {
                PubSubEmptyStateView(
                    isSubscribing: tab.isPubSubSubscribing,
                    isSubscribed: isSubscribed,
                    isCluster: tab.selectedConnection?.mode == .cluster,
                    topicsText: subscribedTopicsText
                )
            } else {
                MessageListView(
                    entries: filtered,
                    selectedEntryID: $selectedEntryID,
                    autoScroll: $autoScroll,
                    lastVisibleEntryID: filtered.last?.id
                )
            }

            Divider()

            if let entry = selectedEntry {
                SelectedMessagePreview(entry: entry)
                Divider()
            }

            PublishStripView(
                channel: $publishChannel,
                message: $publishMessage,
                isPublishing: isPublishing,
                canPublish: tab.activeSession?.isConnected == true,
                onPublish: publish
            )

            Divider()

            PanelFooterBar {
                PubSubStatusIndicator(
                    isSubscribed: isSubscribed,
                    isSubscribing: tab.isPubSubSubscribing
                )
                StatusFooterView(
                    countText: "Showing \(filtered.count) of \(tab.pubSubEntries.count) messages",
                    sizeText: "Received \(tab.pubSubReceivedCount)"
                )
                Spacer()
                // Publish result lives after the spacer: width changes are
                // absorbed by the spacer, so the footer's leading status
                // never reflows when the confirmation fades in and out.
                if let publishFeedback {
                    Label(publishFeedback, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppColor.success)
                        .transition(.opacity)
                }
            }
            .animation(AppAnimation.quick, value: publishFeedback)
        }
        .onAppear {
            if topicInput.isEmpty, isSubscribed {
                topicInput = subscribedTopicsText
            }
            consumePendingPublishDraft()
        }
        .onChange(of: tab.pubSubPendingPublish) { _, _ in
            consumePendingPublishDraft()
        }
    }

    // MARK: - Actions

    /// Fills the publish form from a "Publish Again" handoff.
    private func consumePendingPublishDraft() {
        guard let draft = tab.pubSubPendingPublish else { return }
        tab.pubSubPendingPublish = nil
        publishChannel = draft.channel
        publishMessage = draft.message
    }

    private func toggleSubscription() {
        if isBusy {
            tab.stopPubSub()
        } else {
            subscribe()
        }
    }

    private func subscribe() {
        let subscriptions = PubSubSubscription.parse(topicInput, mode: mode)
        // Reflect the resolved subscriptions (empty input becomes `*`).
        topicInput = subscriptions.map(\.topic).joined(separator: " ")
        tab.startPubSub(subscriptions: subscriptions)
    }

    private func clearMessages() {
        selectedEntryID = nil
        tab.clearPubSubMessages()
    }

    private func publish() {
        let channel = publishChannel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channel.isEmpty, !publishMessage.isEmpty, !isPublishing else { return }
        isPublishing = true
        publishFeedback = nil
        publishFeedbackTask?.cancel()
        let message = publishMessage
        Task {
            let receivers = await tab.publishPubSubMessage(channel: channel, message: message)
            isPublishing = false
            guard let receivers else { return }
            publishMessage = ""
            showPublishFeedback(
                receivers == 0
                    ? "Published (no active subscribers)"
                    : receivers == 1
                        ? "Published to 1 client"
                        : "Published to \(receivers) clients"
            )
        }
    }

    private func showPublishFeedback(_ text: String) {
        publishFeedbackTask?.cancel()
        publishFeedback = text
        publishFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            publishFeedback = nil
        }
    }
}

// MARK: - Subscription Bar

private struct SubscriptionBarView: View {
    @Binding var topicInput: String
    @Binding var mode: PubSubSubscriptionMode
    let isSubscribed: Bool
    let isSubscribing: Bool
    let hasMessages: Bool
    let topicsText: String
    let onToggleSubscription: () -> Void
    let onClearMessages: () -> Void

    private var isInputDisabled: Bool { isSubscribed || isSubscribing }

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            OptionsPicker(
                "Subscription type",
                selection: $mode,
                options: PubSubSubscriptionMode.allCases
            ) { $0.title }
            .disabled(isInputDisabled)
            .help("Channel subscribes to exact names; Pattern matches with globs (PSUBSCRIBE)")

            OwnFocusField { fieldFocused in
                TextField(
                    isSubscribed ? topicsText : mode.inputPlaceholder,
                    text: $topicInput,
                    axis: .vertical
                )
                .font(AppFont.monoBody)
                .lineLimit(1...2)
                .focused(fieldFocused)
                .onSubmit(submitIfIdle)
            }
            .disabled(isInputDisabled)
            .help(isInputDisabled ? "Unsubscribe to change the subscription" : "Topics to subscribe to, space-separated")

            toggleSubscriptionButton
                .disabled(isSubscribing)

            Button("Clear messages", systemImage: "trash", action: onClearMessages)
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .disabled(!hasMessages)
                .help("Clear received messages")
        }
        .panelToolbar(horizontalPadding: AppSpacing.small)

        Divider()
    }

    /// Two branches rather than a ternary: `PrimaryButtonStyle` and
    /// `SecondaryButtonStyle` are distinct types, so `?:` cannot unify them.
    @ViewBuilder
    private var toggleSubscriptionButton: some View {
        if isSubscribed {
            Button(action: onToggleSubscription) {
                Label(buttonTitle, systemImage: buttonIcon)
            }
            .buttonStyle(SecondaryButtonStyle())
        } else {
            Button(action: onToggleSubscription) {
                Label(buttonTitle, systemImage: buttonIcon)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func submitIfIdle() {
        guard !isInputDisabled else { return }
        onToggleSubscription()
    }

    private var buttonTitle: String {
        isSubscribing ? "Subscribing" : isSubscribed ? "Unsubscribe" : "Subscribe"
    }

    private var buttonIcon: String {
        if isSubscribing { return "circle.dotted" }
        return isSubscribed ? "personalhotspot" : "dot.radiowaves.left.and.right"
    }
}

// MARK: - Messages Bar

private struct MessagesBarView: View {
    @Binding var filterText: String
    @Binding var autoScroll: Bool
    let messageCount: Int

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            FilterField("Filter channel or message", text: $filterText)

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.switch)
                .help("Keep the newest messages visible")

            Text("Messages \(messageCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .panelToolbar(horizontalPadding: AppSpacing.small)

        Divider()
    }
}

// MARK: - Empty State

private struct PubSubEmptyStateView: View {
    let isSubscribing: Bool
    let isSubscribed: Bool
    let isCluster: Bool
    let topicsText: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if isSubscribing {
                ContentUnavailableView(
                    "Subscribing",
                    systemImage: "circle.dotted",
                    description: Text("Opening the subscription connection…")
                )
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, AppSpacing.small)
            } else if isSubscribed {
                ContentUnavailableView(
                    "Waiting for messages",
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(
                        topicsText.isEmpty
                            ? "Publish to a subscribed topic from Shell or another client."
                            : "Subscribed to \(topicsText). Publish to a matching topic to see messages here.")
                )
            } else {
                ContentUnavailableView(
                    "Subscribe to channels to receive messages",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text(
                        "Enter channel names or patterns above and press Subscribe. "
                            + "Use Shell or the publish form below to send messages.")
                )
                if isCluster {
                    Label(
                        "Cluster: regular pub/sub is broadcast to every node (Redis 7+); "
                            + "sharded channels (SSUBSCRIBE) only deliver on their owning shard.",
                        systemImage: "info.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, AppSpacing.small)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Message List

private struct MessageListView: View {
    let entries: [PubSubEntry]
    @Binding var selectedEntryID: PubSubEntry.ID?
    @Binding var autoScroll: Bool
    let lastVisibleEntryID: PubSubEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            MessageRowView(
                                entry: entry,
                                isSelected: selectedEntryID == entry.id,
                                onSelect: { selectedEntryID = entry.id }
                            )
                            .id(entry.id)
                        }
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        let distanceFromBottom =
                            geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                        return distanceFromBottom
                    } action: { _, distanceFromBottom in
                        // Auto-disable auto-scroll when the user scrolls away from the bottom.
                        if autoScroll && distanceFromBottom > 60 {
                            autoScroll = false
                        }
                    }
                }
                .onChange(of: lastVisibleEntryID) { _, newValue in
                    guard autoScroll, let newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: AppSpacing.compact) {
            Text("Time")
                .frame(width: 100, alignment: .leading)
            Text("Channel")
                .frame(width: 230, alignment: .leading)
            Text("Message")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.mini)
        .background(AppColor.controlBackground)
    }
}

private struct MessageRowView: View {
    let entry: PubSubEntry
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(TabState.self) private var tab

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AppSpacing.compact) {
                Text(entry.timeText)
                    .frame(width: 100, alignment: .leading)
                    .foregroundStyle(.secondary)
                Text(entry.channelText)
                    .frame(width: 230, alignment: .leading)
                    .foregroundStyle(entry.pattern == nil ? Color.primary : Color.accentColor)
                    .truncationMode(.middle)
                Text(entry.payloadPreview)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .truncationMode(.tail)
            }
            .font(AppFont.monoSubheadline)
            .lineLimit(1)
            .padding(.horizontal, AppSpacing.large)
            .padding(.vertical, AppSpacing.mini)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? (controlActiveState == .inactive
                        ? AppColor.iconHoverBackground : AppColor.selectionBackground)
                    : isHovering ? AppColor.hoverBackground : Color.clear
            )
            .onHover { isHovering = $0 }
        }
        .buttonStyle(.plain)
        .clickCursor()
        .accessibilityLabel("Message on \(entry.channel)")
        .help("Select to preview the full message")
        .contextMenu {
            Button("Publish Again") {
                tab.openInPubSubPublishForm(channel: entry.channel, message: entry.payload)
            }
            Button("Copy PUBLISH Command") {
                copyToPasteboard(entry.publishCommand)
            }
            Divider()
            Button("Copy Channel") {
                copyToPasteboard(entry.channel)
            }
            Button("Copy Message") {
                copyToPasteboard(entry.payload)
            }
        }
    }
}

// MARK: - Selected Message Preview

private struct SelectedMessagePreview: View {
    let entry: PubSubEntry

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            HStack(spacing: AppSpacing.small) {
                Text(entry.timeText)
                    .font(AppFont.monoCaption)
                    .foregroundStyle(.secondary)
                Text(entry.channelText)
                    .font(AppFont.monoCaption)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            Text(entry.payload)
                .font(AppFont.monoSubheadline)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.small)
    }
}

// MARK: - Publish Strip

private struct PublishStripView: View {
    @Binding var channel: String
    @Binding var message: String
    let isPublishing: Bool
    let canPublish: Bool
    let onPublish: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Text("Publish")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            OwnFocusField { fieldFocused in
                TextField("Channel", text: $channel)
                    .font(AppFont.monoBody)
                    .focused(fieldFocused)
                    .onSubmit(onPublish)
            }
            .frame(width: 210)

            OwnFocusField { fieldFocused in
                TextField("Message", text: $message, axis: .vertical)
                    .font(AppFont.monoBody)
                    .lineLimit(1...3)
                    .focused(fieldFocused)
                    .onSubmit(onPublish)
            }

            Button(action: onPublish) {
                Label("Publish", systemImage: "paperplane.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canPublish || isPublishing || channel.trimmingCharacters(in: .whitespaces).isEmpty || message.isEmpty)
            .help("Publish the message with PUBLISH (Return)")
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.small)
    }
}

// MARK: - Status

private struct PubSubStatusIndicator: View {
    let isSubscribed: Bool
    let isSubscribing: Bool

    var body: some View {
        Label(statusText, systemImage: statusIcon)
            .foregroundStyle(isSubscribed || isSubscribing ? AppColor.success : .secondary)
    }

    private var statusText: String {
        if isSubscribing { return "Subscribing" }
        return isSubscribed ? "Subscribed" : "Unsubscribed"
    }

    private var statusIcon: String {
        if isSubscribing { return "circle.dotted" }
        return isSubscribed ? "circle.fill" : "circle"
    }
}
