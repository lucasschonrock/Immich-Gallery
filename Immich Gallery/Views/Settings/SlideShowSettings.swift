//
//  SlideShowSettings.swift
//  Immich Gallery
//
//  Created by mensadi labs on 2025-07-28.
//
//⁠‌‌​​​​‌​‌​‌​‌​​‌​‌‌​‌‌​‌​‌‌​​‌​‌​‌‌​‌‌‌​​‌‌‌​​‌‌​‌‌​​​​‌​‌‌​​‌​​​‌‌​‌​​‌​‌‌​‌‌​​​‌‌​​​​‌​‌‌​​​‌​​‌‌‌​​‌‌⁠

import Foundation
import SwiftUI

// MARK: - Slideshow Settings Component

struct SlideshowSettings: View {
    @Binding var slideshowInterval: Double
    @Binding var slideshowBackgroundColor: String
    @Binding var use24HourClock: Bool
    @Binding var hideOverlay: Bool
    @Binding var showCurrentTimeWidget: Bool
    @Binding var photoDateDisplayMode: String
    @Binding var showLocationOverlay: Bool
    @Binding var enableReflections: Bool
    @Binding var enableKenBurns: Bool
    @Binding var enableShuffle: Bool
    @FocusState.Binding var isMinusFocused: Bool
    @FocusState.Binding var isPlusFocused: Bool
    @FocusState.Binding var focusedColor: String?
    @State private var showPerformanceAlert = false
    
    
    var body: some View {
        VStack(spacing: 12) {
            // Slideshow Interval Setting
            SettingsRow(
                icon: "timer",
                title: "Slideshow Interval",
                subtitle: "Time between slides in slideshow mode",
                content: AnyView(
                    HStack(spacing: 40) {
                        Button(action: {
                            print("clicked -")
                            print(slideshowInterval)
                            if slideshowInterval > 8 {
                                slideshowInterval -= 1
                            }
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(isMinusFocused ? .white : .blue)
                                .font(.title2)
                        }
                        .buttonStyle(CustomFocusButtonStyle())
                        .focused($isMinusFocused)
                        
                        Text("\(Int(slideshowInterval))s")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .frame(minWidth: 50)
                            .id("slideshow-interval-\(Int(slideshowInterval))")
                        
                        Button(action: {
                            print("clicked +")
                            print(slideshowInterval)
                            if slideshowInterval < 15 {
                                slideshowInterval += 1
                            }
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(isPlusFocused ? .white : .blue)
                                .font(.title2)
                        }
                        .buttonStyle(CustomFocusButtonStyle())
                        .focused($isPlusFocused)
                    }
                )
            )
            
            // Slideshow Background Color Setting
            SettingsRow(
                icon: "paintbrush",
                title: "Slideshow Background",
                subtitle: "Background color for slideshow mode",
                content: AnyView(
                    HStack {
                        // Color preview circle
                        Group {
                            if slideshowBackgroundColor == "auto" {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(
                                            colors: [.red, .orange, .yellow, .green, .blue, .purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ))
                                    Image(systemName: "paintpalette.fill")
                                        .foregroundColor(.white)
                                        .font(.caption)
                                }
                            } else {
                                Circle()
                                    .fill(getBackgroundColor(slideshowBackgroundColor))
                            }
                        }
                        .frame(width: 32, height: 32)
                        
                        Picker("Background Color", selection: $slideshowBackgroundColor) {
                            ForEach(["auto", "black", "white", "gray", "blue", "purple"], id: \.self) { color in
                                Text(color.capitalized).tag(color)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: slideshowBackgroundColor) { _, newValue in
                            if newValue == "auto" {
                                showPerformanceAlert = true
                            }
                        }
                    }
                )
            )
            
            // Clock Format Setting
             SettingsRow(
                 icon: "clock",
                 title: "Clock Format",
                 subtitle: "Time format for slideshow overlay.",
                 content: AnyView(
                     Picker("Clock Format", selection: $use24HourClock) {
                         Text("12 Hour").tag(false)
                         Text("24 Hour").tag(true)
                     }
                         .pickerStyle(.menu)
                         .frame(width: 300, alignment: .trailing)
                 )
             )
            
            SettingsRow(
                icon: "camera.macro.circle",
                title: "Image Effects",
                subtitle: "Choose visual effects for slideshow images",
                content: AnyView(
                    Picker("Image Effects", selection: Binding(
                        get: {
                            if enableKenBurns {
                                return "kenBurns"
                            } else if enableReflections {
                                return "reflections"
                            } else {
                                return "none"
                            }
                        },
                        set: { newValue in
                            switch newValue {
                            case "kenBurns":
                                enableKenBurns = true
                                enableReflections = false
                            case "reflections":
                                enableKenBurns = false
                                enableReflections = true
                            default: // "none"
                                enableKenBurns = false
                                enableReflections = false
                            }
                        }
                    )) {
                        Text("None").tag("none")
                        Text("Reflections").tag("reflections")
                        Text("Pan and Zoom").tag("kenBurns")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 400, alignment: .trailing)
                )
            )
            
            SettingsRow(
                icon: "shuffle",
                title: "Shuffle Images (beta)",
                subtitle: "Randomly shuffle image order during slideshow (This uses `/search/random` endpoint. Does not work when viewing an album that is shared-in. To my knowledge, this is a limitation of Immich random endpoint. If you disagree, open a GH issue with details.) ",
                content: AnyView(
                    Picker("Shuffle Images", selection: $enableShuffle) {
                        Text("Off").tag(false)
                        Text("On").tag(true)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 300, alignment: .trailing)
                ),
                isOn: enableShuffle
            )
            
            // MARK: - Image Overlay group
            HStack {
                Text("Image Overlay")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)

            SettingsRow(
                icon: "eye",
                title: "Show Image Overlays",
                subtitle: "Master switch for the clock, photo date, and location overlays. Applies to slideshow and fullscreen view.",
                content: AnyView(
                    Picker("Show Image Overlays", selection: Binding(
                        get: { !hideOverlay },
                        set: { hideOverlay = !$0 }
                    )) {
                        Text("Show").tag(true)
                        Text("Hide").tag(false)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 300, alignment: .trailing)
                ),
                isOn: !hideOverlay
            )

            VStack(spacing: 12) {
                SettingsRow(
                    icon: "clock.badge",
                    title: "Current Time Widget",
                    subtitle: "Show the large current time and today's date in the slideshow overlay.",
                    content: AnyView(
                        Picker("Current Time Widget", selection: $showCurrentTimeWidget) {
                            Text("Show").tag(true)
                            Text("Hide").tag(false)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 300, alignment: .trailing)
                    ),
                    isOn: showCurrentTimeWidget
                )

                SettingsRow(
                    icon: "calendar",
                    title: "Photo Date",
                    subtitle: "What to show for the photo's taken date in the overlay.",
                    content: AnyView(
                        Picker("Photo Date", selection: $photoDateDisplayMode) {
                            Text("Date & Time").tag("dateAndTime")
                            Text("Date Only").tag("dateOnly")
                            Text("Hidden").tag("none")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 300, alignment: .trailing)
                    ),
                    isOn: photoDateDisplayMode != "none"
                )

                SettingsRow(
                    icon: "location",
                    title: "Location",
                    subtitle: "Show the photo's location (city, state, country) in the overlay.",
                    content: AnyView(
                        Picker("Location", selection: $showLocationOverlay) {
                            Text("Show").tag(true)
                            Text("Hide").tag(false)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 300, alignment: .trailing)
                    ),
                    isOn: showLocationOverlay
                )
            }
            .opacity(hideOverlay ? 0.4 : 1.0)
            .disabled(hideOverlay)
        }
        .alert("Performance Warning", isPresented: $showPerformanceAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Enable Auto Color") {
                slideshowBackgroundColor = "auto"
            }
        } message: {
            Text("Auto background color analyzes each image to extract dominant colors. This may cause performance issues with large images during slideshow transitions.")
        }
    }
    
    private func getBackgroundColor(_ colorName: String) -> Color {
        switch colorName {
        case "auto": return .black // Fallback for preview, actual auto color is handled in slideshow
        case "black": return .black
        case "white": return .white
        case "gray": return .gray
        case "blue": return .blue
        case "purple": return .purple
        default: return .black
        }
    }
}


#Preview {
    @State var slideshowInterval: Double = 8.0
    @State var slideshowBackgroundColor = "white"
    @State var use24HourClock = true
    @State var hideOverlay = true
    @State var showCurrentTimeWidget = true
    @State var photoDateDisplayMode = "dateAndTime"
    @State var showLocationOverlay = true
    @State var enableReflections = true
    @State var enableKenBurns = false
    @State var enableShuffle = false
    @FocusState var isMinusFocused: Bool
    @FocusState var isPlusFocused: Bool
    @FocusState var focusedColor: String?
    
    return SlideshowSettings(
        slideshowInterval: $slideshowInterval,
        slideshowBackgroundColor: $slideshowBackgroundColor,
        use24HourClock: $use24HourClock,
        hideOverlay: $hideOverlay,
        showCurrentTimeWidget: $showCurrentTimeWidget,
        photoDateDisplayMode: $photoDateDisplayMode,
        showLocationOverlay: $showLocationOverlay,
        enableReflections: $enableReflections,
        enableKenBurns: $enableKenBurns,
        enableShuffle: $enableShuffle,
        isMinusFocused: $isMinusFocused,
        isPlusFocused: $isPlusFocused,
        focusedColor: $focusedColor
    )
    .preferredColorScheme(.light)
    .padding()
}

