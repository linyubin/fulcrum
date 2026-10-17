import SwiftUI

/// About panel: `Fulcrum v<version>`, the product site and the issue
/// tracker. Shown from the menu bar's "About Fulcrum", the app menu, and
/// via the `about` launcher row (about.open delegates here). License:
/// BUSL-1.1 — source-available, not opensource.
struct AboutPanelView: View {
    /// The version compiled into this binary — the same number the
    /// backend reports and the updater compares against. Info.plist is
    /// packaging metadata that can drift on a hand-assembled bundle;
    /// showing it here would misstate what is actually running.
    private var version: String { RivetGeneratedConfig.version }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 44))
                .foregroundStyle(FulcrumTheme.accent)
            Text("Fulcrum v\(version)")
                .font(.system(size: 15, weight: .semibold))
            Text(I18nService.shared.t("aboutContent"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(I18nService.shared.t("aboutLicense"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Link(I18nService.shared.t("aboutWebsite"),
                     destination: URL(string: "https://fulcrum.jrtx.site")!)
                Link(I18nService.shared.t("aboutReportIssue"),
                     destination: URL(string:
                        "https://github.com/turinglambdaai/fulcrum/issues")!)
            }
            .font(.system(size: 12))
        }
        .padding(28)
        .frame(width: 340)
    }
}
