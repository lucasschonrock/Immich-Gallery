//
//  LockedFolderUnlockView.swift
//  Immich Gallery
//

import SwiftUI

enum LockedFolderAlbum {
    static let id = "smart_locked"
    static let pinLength = 6

    static func make(user: SavedUser, assetCount: Int = 0) -> ImmichAlbum {
        let owner = Owner(
            id: user.id,
            email: user.email,
            name: user.name,
            profileImagePath: "",
            profileChangedAt: "",
            avatarColor: "primary"
        )

        let now = ISO8601DateFormatter().string(from: Date())
        return ImmichAlbum(
            id: id,
            albumName: "Private",
            description: "Protected",
            albumThumbnailAssetId: nil,
            createdAt: now,
            updatedAt: now,
            albumUsers: [],
            assets: [],
            assetCount: assetCount,
            ownerId: user.id,
            owner: owner,
            shared: false,
            hasSharedLink: false,
            isActivityEnabled: false,
            lastModifiedAssetTimestamp: nil,
            order: nil,
            startDate: nil,
            endDate: nil
        )
    }
}

private enum PinPadKey: Hashable {
    case digit(Int)
    case delete
}

struct LockedPinEntryPanel: View {
    @Binding var pinCode: String
    let errorMessage: String?
    let isUnlocking: Bool
    let onUnlock: () -> Void

    @FocusState private var focusedKey: PinPadKey?
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 36) {
            VStack(spacing: 14) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(.white)

                Text("Private")
                    .font(.system(size: 52, weight: .semibold))

                Text("Enter your 6-digit PIN")
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }

            pinDots
                .offset(x: shakeOffset)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 720)
            } else if isUnlocking {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
            } else {
                Color.clear.frame(height: 36)
            }

            pinPad
                .disabled(isUnlocking)
                .opacity(isUnlocking ? 0.45 : 1)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 48)
        .frame(minWidth: 820)
        .defaultFocus($focusedKey, .digit(5))
        .onAppear {
            focusedKey = .digit(5)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                focusedKey = .digit(5)
            }
        }
        .onChange(of: pinCode) { _, newValue in
            let digits = String(newValue.filter(\.isNumber).prefix(LockedFolderAlbum.pinLength))
            if digits != newValue {
                pinCode = digits
                return
            }
            if digits.count == LockedFolderAlbum.pinLength, !isUnlocking {
                onUnlock()
            }
        }
        .onChange(of: errorMessage) { _, message in
            guard message != nil else { return }
            shakePinDots()
        }
    }

    private var pinDots: some View {
        HStack(spacing: 24) {
            ForEach(0..<LockedFolderAlbum.pinLength, id: \.self) { index in
                Circle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 2)
                    .background {
                        Circle()
                            .fill(index < pinCode.count ? Color.white : Color.clear)
                    }
                    .frame(width: 34, height: 34)
                    .scaleEffect(index < pinCode.count ? 1.08 : 1)
                    .animation(.easeOut(duration: 0.12), value: pinCode.count)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN")
        .accessibilityValue("\(min(pinCode.count, LockedFolderAlbum.pinLength)) of \(LockedFolderAlbum.pinLength) digits entered")
    }

    private var pinPad: some View {
        VStack(spacing: 18) {
            ForEach(Array(padRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 18) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        if let key {
                            padButton(for: key)
                        } else {
                            Color.clear
                                .frame(width: 110, height: 110)
                        }
                    }
                }
            }
        }
        .focusSection()
    }

    private var padRows: [[PinPadKey?]] {
        [
            [.digit(1), .digit(2), .digit(3)],
            [.digit(4), .digit(5), .digit(6)],
            [.digit(7), .digit(8), .digit(9)],
            [.delete, .digit(0), nil]
        ]
    }

    @ViewBuilder
    private func padButton(for key: PinPadKey) -> some View {
        Button {
            handle(key)
        } label: {
            Group {
                switch key {
                case .digit(let value):
                    Text("\(value)")
                        .font(.system(size: 38, weight: .medium))
                case .delete:
                    Image(systemName: "delete.backward")
                        .font(.system(size: 32, weight: .medium))
                }
            }
            .frame(width: 110, height: 110)
        }
        .buttonStyle(PinPadButtonStyle())
        .focused($focusedKey, equals: key)
        .accessibilityLabel(accessibilityLabel(for: key))
    }

    private func handle(_ key: PinPadKey) {
        switch key {
        case .digit(let value):
            guard pinCode.count < LockedFolderAlbum.pinLength else { return }
            pinCode.append(String(value))
        case .delete:
            guard !pinCode.isEmpty else { return }
            pinCode.removeLast()
        }
    }

    private func accessibilityLabel(for key: PinPadKey) -> String {
        switch key {
        case .digit(let value):
            return "\(value)"
        case .delete:
            return "Delete"
        }
    }

    private func shakePinDots() {
        let offsets: [CGFloat] = [-18, 18, -12, 12, 0]
        for (index, offset) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045 * Double(index)) {
                withAnimation(.easeInOut(duration: 0.045)) {
                    shakeOffset = offset
                }
            }
        }
    }
}

private struct PinPadButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .background(
                Circle()
                    .fill(isFocused ? Color.white : Color.white.opacity(0.16))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : (isFocused ? 1.1 : 1.0))
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

#Preview("Locked PIN Entry") {
    LockedPinEntryPanelPreview()
}

private struct LockedPinEntryPanelPreview: View {
    @State private var pinCode = "12"

    var body: some View {
        LockedPinEntryPanel(
            pinCode: $pinCode,
            errorMessage: "Incorrect PIN. Please try again.",
            isUnlocking: false,
            onUnlock: {}
        )
    }
}
