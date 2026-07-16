//
//  SharedGradientBackground.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2025-06-29.
//

import SwiftUI

enum AppBackgroundStyle: String, CaseIterable {
    case ocean
    case midnight
    case forest
    case sunset
    case graphite

    var displayName: String {
        switch self {
        case .ocean: return "Ocean"
        case .midnight: return "Midnight"
        case .forest: return "Forest"
        case .sunset: return "Sunset"
        case .graphite: return "Graphite"
        }
    }

    var gradientColors: [Color] {
        switch self {
        case .ocean:
            return [
                Color(red: 44/255, green: 83/255, blue: 100/255),
                Color(red: 44/255, green: 83/255, blue: 100/255),
                Color(red: 44/255, green: 83/255, blue: 100/255)
            ]
        case .midnight:
            return [
                .black,
                .black,
                .black
            ]
        case .forest:
            return [
                Color(red: 18/255, green: 52/255, blue: 44/255),
                Color(red: 30/255, green: 78/255, blue: 65/255),
                Color(red: 45/255, green: 98/255, blue: 83/255)
            ]
        case .sunset:
            return [
                Color(red: 78/255, green: 36/255, blue: 65/255),
                Color(red: 118/255, green: 58/255, blue: 83/255),
                Color(red: 166/255, green: 82/255, blue: 79/255)
            ]
        case .graphite:
            return [
                Color(red: 30/255, green: 34/255, blue: 40/255),
                Color(red: 42/255, green: 47/255, blue: 54/255),
                Color(red: 58/255, green: 64/255, blue: 72/255)
            ]
        }
    }
}

// Shared background gradient for consistent styling across the app
struct SharedGradientBackground: View {
    @AppStorage(UserDefaultsKeys.appBackgroundStyle) private var appBackgroundStyle = AppBackgroundStyle.graphite.rawValue

    private var selectedStyle: AppBackgroundStyle {
        AppBackgroundStyle(rawValue: appBackgroundStyle) ?? .graphite
    }

    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: selectedStyle.gradientColors),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// Shared utility function for background colors
func getBackgroundColor(_ colorString: String) -> Color {
    switch colorString {
    case "auto":
        return .black // Fallback for non-slideshow contexts
    case "black":
        return .black
    case "white":
        return .white
    case "gray":
        return .gray
    case "blue":
        return .blue
    case "purple":
        return .purple
    default:
        return .black
    }
}

// Custom button style to remove default tvOS focus ring
struct CustomFocusButtonStyle: ButtonStyle {
    @Environment(\.isFocused) var isFocused
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : (isFocused ? 1.2 : 1.0))
            .background(
                Circle()
                    .fill(isFocused ? Color.white.opacity(0.2) : Color.clear)
                    .frame(width: 44, height: 44)
            )
            .animation(.easeInOut(duration: 0.2), value: isFocused)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// Custom focusable button style for color selection
struct ColorSelectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

struct SharedOpaqueBackground: View {
    @AppStorage(UserDefaultsKeys.appBackgroundStyle) private var appBackgroundStyle = AppBackgroundStyle.graphite.rawValue

    private var selectedStyle: AppBackgroundStyle {
        AppBackgroundStyle(rawValue: appBackgroundStyle) ?? .graphite
    }

    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: selectedStyle.gradientColors),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

#Preview {
    SharedGradientBackground()
}
