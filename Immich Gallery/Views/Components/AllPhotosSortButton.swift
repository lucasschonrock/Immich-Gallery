import SwiftUI

struct AllPhotosSortButton: View {
    let sortOrder: String
    let action: () -> Void
    var accessibilityLabel = "Sort photos by date taken"

    private var orderLabel: String {
        sortOrder == "asc" ? "Oldest" : "Newest"
    }

    var body: some View {
        Button(action: action) {
            Label(orderLabel, systemImage: "arrow.up.arrow.down")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(orderLabel)
        .accessibilityHint("Toggles the date sort direction")
    }
}
