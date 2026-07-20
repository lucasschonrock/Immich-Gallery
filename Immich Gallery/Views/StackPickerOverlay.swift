import SwiftUI

struct StackPickerOverlay: View {
    let assets: [ImmichAsset]
    let selectedAssetId: String
    @ObservedObject var assetService: AssetService
    let onSelect: (ImmichAsset) -> Void
    @FocusState private var focusedAssetId: String?

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Label("Choose from stack", systemImage: "square.stack.3d.up.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("Menu to close")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 30) {
                    ForEach(assets) { asset in
                        Button {
                            onSelect(asset)
                        } label: {
                            AssetThumbnailView(
                                asset: asset,
                                assetService: assetService,
                                isFocused: focusedAssetId == asset.id,
                                showsDateOverlay: false,
                                showsStackIndicator: false,
                                thumbnailSize: 250
                            )
                        }
                        .frame(width: 250, height: 290)
                        .id(asset.id)
                        .focused($focusedAssetId, equals: asset.id)
                        .animation(.easeInOut(duration: 0.2), value: focusedAssetId)
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .focusSection()
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 32)
        .background(.black.opacity(0.92))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                focusedAssetId = assets.contains { $0.id == selectedAssetId }
                    ? selectedAssetId
                    : assets.first?.id
            }
        }
    }
}
