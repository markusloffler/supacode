import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Settings sub-section for managing scripts shared across every repository.
public struct GlobalScriptsSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  @Shared(.markdownEditorEnabled) private var markdownEditorEnabled: Bool
  @Shared(.markdownEditorTheme) private var markdownEditorTheme: MarkdownEditorThemeChoice
  @Shared(.markdownEditModeAppearance) private var markdownEditModeAppearance: MarkdownEditorAppearance
  @Shared(.markdownReadModeAppearance) private var markdownReadModeAppearance: MarkdownEditorAppearance

  public init(store: StoreOf<SettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    ScrollViewReader { proxy in
      Form {
        // A hook, not a menu script, so it sits outside the global-scripts list and shows even
        // when there are none. A repo's own script wins; empty here uses the system default app.
        LifecycleScriptSection(
          text: $store.openFileScript,
          title: "Open File Script",
          subtitle: "Fallback for opening a double-clicked file when the repository sets none.",
          icon: "arrow.up.forward.app",
          iconColor: .teal,
          footerExample: "nvim \"$SUPACODE_FILE_PATH\""
        )

        // MARK: Markdown editor
        Section {
          Toggle("Open Markdown files in built-in editor", isOn: Binding($markdownEditorEnabled))
            .help("Double-clicked .md files open in an editor pane instead of the open-file script.")
          Picker("Editor theme", selection: Binding($markdownEditorTheme)) {
            ForEach(MarkdownEditorThemeChoice.allCases) { Text($0.title).tag($0) }
          }
          .help("Typography and colors of the Markdown editor.")
          Picker("Editor appearance", selection: Binding($markdownEditModeAppearance)) {
            ForEach(MarkdownEditorAppearance.allCases) { Text($0.title).tag($0) }
          }
          .help("Light or dark editor in edit mode, independent of the app.")
          Picker("Read mode appearance", selection: Binding($markdownReadModeAppearance)) {
            ForEach(MarkdownEditorAppearance.allCases) { Text($0.title).tag($0) }
          }
          .help("Light or dark editor in read mode (⌘/), independent of the app.")
        }

        Section(
          footer: Text(
            store.globalScripts.isEmpty
              ? "Add a script to make it available in every repository's toolbar and command palette."
              : "Global scripts are available in every repository's toolbar and command palette."
          )
        ) {}

        ForEach($store.globalScripts) { $script in
          Section {
            TextField("Name", text: $script.name)
            LabeledContent("Color") {
              ColorSwatchRow(color: $script.tintColor)
            }
            ScriptCommandEditor(text: $script.command, label: script.displayName)
            Button("Remove Script…", role: .destructive) {
              store.send(.removeGlobalScript(script.id))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Remove this script.")
          } header: {
            Label {
              Text("\(script.displayName) Script")
                .appFont(.body)
                .bold()
            } icon: {
              Image(systemName: script.resolvedSystemImage)
                .foregroundStyle(script.resolvedTintColor.color)
                .accessibilityHidden(true)
            }
            .labelStyle(.verticallyCentered)
          }
          .id(script.id)
        }
      }
      .formStyle(.grouped)
      .contentMargins(.trailing, 6, for: .scrollIndicators)
      .padding(.top, -20)
      .padding(.leading, -8)
      .padding(.trailing, -6)
      // Scroll the newly appended section into view; otherwise an add gives no
      // visible feedback when the form is already taller than the window.
      .onChange(of: store.globalScripts.count) { oldCount, newCount in
        guard newCount > oldCount, let last = store.globalScripts.last else { return }
        withAnimation { proxy.scrollTo(last.id, anchor: .top) }
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.addGlobalScript)
        } label: {
          Image(systemName: "plus")
            .accessibilityLabel("Add Global Script")
        }
        .help("Add a new global script.")
      }
    }
    .dismissSystemColorPanelOnDisappear()
  }
}
