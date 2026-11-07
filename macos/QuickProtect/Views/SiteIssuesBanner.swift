import SwiftUI

/// Slim strip above the grid naming each site that currently contributes no
/// cameras, while another site still does. One line per site; a site whose
/// certificate changed gets a Review button (the decision stays deliberate),
/// the others a Retry.
struct SiteIssuesBanner: View {
    let issues: [ProtectHub.SiteIssue]
    let hub: ProtectHub
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 1) {
            ForEach(issues) { issue in
                row(issue)
            }
        }
    }

    private func row(_ issue: ProtectHub.SiteIssue) -> some View {
        HStack(spacing: 8) {
            Image(systemName: issue.isCertificateChange
                  ? "lock.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(AuroraTokens.statusOrange)
            Text(issue.siteName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
            Text(issue.message)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(issue.message)
            Spacer(minLength: 8)
            if issue.isCertificateChange {
                Button(String(localized: "Review Certificate…")) {
                    if let service = hub.service(forSite: issue.siteID) {
                        CertificateReviewAlert.present(service: service)
                    }
                }
                .buttonStyle(AuroraStatePillButtonStyle(primary: false))
            } else {
                Button(String(localized: "Retry")) {
                    Task {
                        await hub.service(forSite: issue.siteID)?.fetchCameras(forced: true)
                        hub.recompute()
                    }
                }
                .buttonStyle(AuroraStatePillButtonStyle(primary: false))
                Button(String(localized: "Open Settings"), action: onOpenSettings)
                    .buttonStyle(AuroraStatePillButtonStyle(primary: false))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AuroraTokens.statusOrange.opacity(0.14))
        .accessibilityElement(children: .combine)
    }
}

/// Small chip naming a camera's site, shown next to its name only while more
/// than one site is configured.
struct SiteBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(.white.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.white.opacity(0.16)))
            .fixedSize()
            .accessibilityLabel(String(localized: "Site \(name)"))
    }
}
