import SupacodeSettingsShared
import SwiftUI

struct RepoSectionHeaderView: View {
  let name: String
  let customTitle: String?
  let color: RepositoryColor?
  let isRemoving: Bool
  /// `[user@]host[:port]` when the repository lives on an SSH host, else nil;
  /// surfaces a `wifi` glyph beside the title, full value shown on hover.
  var hostInfo: String?
  /// Remote repository whose SSH listing is still resolving; shows a spinner.
  var isResolving: Bool = false

  private var displayName: String {
    Repository.sidebarDisplayName(custom: customTitle, fallback: name)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SidebarSeparatorAboveHeader()
      titleRow
    }
  }

  private var titleRow: some View {
    HStack {
      HStack(spacing: 4) {
        Text(displayName).foregroundStyle(color?.color ?? .secondary)
        if let hostInfo {
          Image(systemName: "wifi")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .help(hostInfo)
            .accessibilityLabel("Remote host \(hostInfo)")
        }
      }
      // `appFontInheriting` leaves Default-scale text on the list's own header
      // font, so explicitly opt in to a larger size here instead.
      .appFont(.headline, weight: .semibold)
      .opacity(0.8)
      if isRemoving {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Removing repository")
      } else if isResolving {
        ProgressView()
          .controlSize(.mini)
          .accessibilityLabel("Connecting to remote")
      }
    }
  }
}

extension EnvironmentValues {
  /// Set on the first section after the Pinned/Active highlight sections, whose
  /// header then draws a divider on top to set the hoisted rows apart.
  @Entry var sidebarShowsSeparatorAbove = false
}

/// The divider a section header draws on top when it follows the highlight
/// sections; renders nothing otherwise.
struct SidebarSeparatorAboveHeader: View {
  @Environment(\.sidebarShowsSeparatorAbove) private var showsSeparator

  var body: some View {
    if showsSeparator {
      // The VStack pins the orientation: a bare Divider in a folder's otherwise
      // empty header lays out horizontally and renders as a vertical stripe.
      VStack(spacing: 0) {
        Divider()
      }
      .frame(maxWidth: .infinity)
      .padding(.bottom, 6)
      .accessibilityHidden(true)
    }
  }
}
