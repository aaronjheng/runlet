import SwiftUI

// MARK: - Connecting View

struct ConnectingView: View {
    @Environment(TabState.self) private var tab
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: AppSpacing.xLarge) {
            ZStack {
                Circle()
                    .stroke(.tint.opacity(0.2), lineWidth: 4)
                    .frame(width: 60, height: 60)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(isPulsing ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isPulsing)
            }
            .onAppear { isPulsing = true }

            if let pending = tab.pendingConnection {
                Text("Connecting to \(pending.name)")
                    .font(.title3)
                    .bold()
                Text(pending.address)
                    .foregroundStyle(.secondary)
                    .font(AppFont.dataCell)
            }
            Button("Cancel") { tab.cancelConnection() }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, AppSpacing.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(tab.pendingConnection.map { "Connecting to \($0.name)" } ?? "Connecting")
    }
}
