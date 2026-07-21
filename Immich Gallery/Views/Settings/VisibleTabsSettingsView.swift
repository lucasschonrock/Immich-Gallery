import SwiftUI

struct VisibleTabsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedTab: TabName?
    @State private var selection: Set<TabName>
    @State private var defaultTab: TabName

    let onApply: (Set<TabName>, TabName) -> Void

    private let tabs: [TabName] = [
        .photos,
        .albums,
        .people,
        .tags,
        .folders,
        .explore,
        .search,
    ]

    init(
        initialSelection: Set<TabName>,
        initialDefaultTab: TabName,
        onApply: @escaping (Set<TabName>, TabName) -> Void
    ) {
        let safeSelection: Set<TabName> = initialSelection.isEmpty ? [.photos] : initialSelection
        let safeDefaultTab = safeSelection.contains(initialDefaultTab)
            ? initialDefaultTab
            : safeSelection.sorted { $0.rawValue < $1.rawValue }.first ?? .photos

        _selection = State(initialValue: safeSelection)
        _defaultTab = State(initialValue: safeDefaultTab)
        self.onApply = onApply
    }

    var body: some View {
        ZStack {
            SharedGradientBackground()
                .ignoresSafeArea()

            VStack(spacing: 32) {
                VStack(spacing: 10) {
                    Text("Visible Tabs")
                        .font(.largeTitle.bold())

                    Text("Choose which tabs appear in the main navigation.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(tabs, id: \.self) { tab in
                            Button(action: { toggle(tab) }) {
                                HStack(spacing: 20) {
                                    Image(systemName: tab.iconName)
                                        .frame(width: 44)

                                    Text(tab.title)

                                    Spacer()

                                    Image(systemName: selection.contains(tab) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selection.contains(tab) ? .green : .secondary)
                                }
                                .frame(width: 680)
                            }
                            .buttonStyle(.bordered)
                            .focused($focusedTab, equals: tab)
                            .disabled(selection.count == 1 && selection.contains(tab))
                            .accessibilityValue(selection.contains(tab) ? "Visible" : "Hidden")
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.vertical, 24)
                }
                .frame(maxHeight: 460)

                HStack(spacing: 24) {
                    Label("Default Tab", systemImage: "house")

                    Spacer()

                    Picker("Default Tab", selection: $defaultTab) {
                        ForEach(defaultTabs, id: \.self) { tab in
                            Text(tab == .photos ? "All Photos" : tab.title)
                                .tag(tab)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 300, alignment: .trailing)
                }
                .frame(width: 680)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(spacing: 28) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button("Done") {
                        onApply(selection, defaultTab)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 50)
        }
        .onAppear {
            focusedTab = tabs.first
        }
    }

    private func toggle(_ tab: TabName) {
        if selection.contains(tab) {
            guard selection.count > 1 else { return }
            selection.remove(tab)

            if defaultTab == tab {
                defaultTab = selection.sorted { $0.rawValue < $1.rawValue }.first ?? .photos
            }
        } else {
            selection.insert(tab)
        }
    }

    private var defaultTabs: [TabName] {
        tabs.filter(selection.contains)
    }
}
