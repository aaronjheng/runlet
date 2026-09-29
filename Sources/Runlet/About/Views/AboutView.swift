import AppKit
import SwiftUI

/// Contents of the About panel opened from `Runlet → About Runlet`.
///
/// The system panel (`orderFrontStandardAboutPanel`) has no room for a
/// License button, so the app shows its own window instead: icon, version,
/// one-line description, the License button, and the copyright line taken
/// from the bundled `LICENSE`.
struct AboutView: View {
    let onShowLicense: () -> Void

    var body: some View {
        VStack(spacing: AppSpacing.medium) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: AppSize.aboutIconSide, height: AppSize.aboutIconSide)

            VStack(spacing: AppSpacing.xSmall) {
                Text("Runlet")
                    .font(.title2)
                    .bold()

                Text(Self.versionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Native macOS Redis client")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            Button("License", systemImage: "doc.text", action: onShowLicense)
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut("l", modifiers: .command)
                .help("Show the Runlet license text")

            if !AppLicense.copyrightLine.isEmpty {
                Text(AppLicense.copyrightLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, AppSpacing.xLarge + AppSize.titlebarClearance)
        .padding(.horizontal, AppSpacing.xLarge)
        .padding(.bottom, AppSpacing.xLarge)
        .frame(width: AppSize.aboutPanelWidth, height: AppSize.aboutPanelHeight)
        .background(AppColor.windowBackground)
    }

    /// `Version 1.0 (128)`, matching the system panel's wording, so a build
    /// number bump needs no code change.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }
}
