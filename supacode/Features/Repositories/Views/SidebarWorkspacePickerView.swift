import ComposableArchitecture
import SwiftUI

/// Filter pinned above the sidebar list that narrows the rendered sections to
/// a single numbered workspace. Entries come from the reducer-cached
/// `SidebarStructure.WorkspaceSelector`, so the menu only ever lists numbers a
/// repository is actually filed under — and the whole control stays hidden
/// until at least one repository has been assigned one in Customize Appearance.
struct SidebarWorkspacePickerView: View {
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    let workspaces = store.state.sidebarStructure.workspaces
    if workspaces.isVisible {
      Picker("Workspace", selection: selection(current: workspaces.selected)) {
        Text("All Workspaces").tag(Int?.none)
        ForEach(workspaces.available, id: \.self) { number in
          Text("Workspace \(number)").tag(Int?.some(number))
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.top, 2)
      .padding(.bottom, 10)
      .background(.bar)
      .overlay(alignment: .bottom) { Divider() }
      .help("Show only the repositories filed under the selected workspace")
      .accessibilityLabel("Workspace filter")
    }
  }

  private func selection(current: Int?) -> Binding<Int?> {
    Binding(
      get: { current },
      set: { newValue in
        guard newValue != current else { return }
        store.send(.setSidebarWorkspace(newValue))
      }
    )
  }
}
