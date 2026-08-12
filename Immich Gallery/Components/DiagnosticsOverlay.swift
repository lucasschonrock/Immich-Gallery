//
//  DiagnosticsOverlay.swift
//  Immich Gallery
//
//  Created by mensadi-labs on 2026-08-12.
//

import Combine
import SwiftUI

// TEMP DEBUG (remove with RenderStormStats): an on-screen version of the
// render-storm log. Attach with `.diagnosticsOverlay()` anywhere; it is off
// unless the user turns on "Diagnostics Overlay" in Settings, which lets a
// field reporter without a Mac photograph the numbers for us.
struct DiagnosticsOverlay: View {
    // Polling instead of observing: RenderStormStats is deliberately not an
    // ObservableObject, because a publisher that fired on every tick would
    // re-render this overlay thousands of times a second and become the very
    // render storm it is measuring.
    private static let sampleInterval: TimeInterval = 1.0

    @State private var snapshot = RenderStormStats.Snapshot()
    private let ticker = Timer.publish(every: DiagnosticsOverlay.sampleInterval, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RENDER STORM")
            Text("body   \(snapshot.bodyEvalsPerSecond)/s  peak \(snapshot.peakBodyEvalsPerSecond)")
            Text("cache  \(snapshot.publishesPerSecond)/s  peak \(snapshot.peakPublishesPerSecond)")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundColor(.white)
        .padding(10)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .padding(40)
        .onReceive(ticker) { _ in
            snapshot = RenderStormStats.snapshot()
        }
    }
}

/// Shows the overlay only when the setting is on. The condition lives INSIDE the
/// always-applied overlay (an empty overlay builder costs nothing) rather than
/// branching around `content`: an if/else here would give the two branches
/// different view identities, so flipping the toggle would reset all state in
/// the subtree it wraps — for ContentView, the entire main interface.
private struct DiagnosticsOverlayModifier: ViewModifier {
    @AppStorage(UserDefaultsKeys.showDiagnosticsOverlay) private var showDiagnosticsOverlay = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if showDiagnosticsOverlay {
                DiagnosticsOverlay()
                    // Must stay invisible to the focus engine it is measuring.
                    .allowsHitTesting(false)
                    .focusable(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func diagnosticsOverlay() -> some View {
        modifier(DiagnosticsOverlayModifier())
    }
}
