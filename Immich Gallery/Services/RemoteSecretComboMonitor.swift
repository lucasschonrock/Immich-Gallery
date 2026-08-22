//
//  RemoteSecretComboMonitor.swift
//  Immich Gallery
//
//  The Siri Remote mute button is not delivered to apps (no UIPress type, not
//  in the Game Controller profile). Play/Pause four times in a row is the
//  combo that actually works. If a controller ever exposes a button named
//  "mute", that counts the same way.
//

import Combine
import Foundation
import GameController

@MainActor
final class RemoteSecretComboMonitor: ObservableObject {
    static let requiredPressCount = 4
    static let pressWindow: TimeInterval = 2.5

    @Published var shouldPresentUnlock = false

    private var pressCount = 0
    private var lastPressDate: Date?
    private var controllerObservers: [NSObjectProtocol] = []
    private var isMonitoringControllers = false

    func recordSecretPress() {
        let now = Date()
        if let lastPressDate, now.timeIntervalSince(lastPressDate) > Self.pressWindow {
            pressCount = 0
        }
        lastPressDate = now
        pressCount += 1

        if pressCount >= Self.requiredPressCount {
            pressCount = 0
            shouldPresentUnlock = true
        }
    }

    func acknowledgePresentation() {
        shouldPresentUnlock = false
        pressCount = 0
        lastPressDate = nil
    }

    func startControllerMonitoring() {
        guard !isMonitoringControllers else { return }
        isMonitoringControllers = true

        controllerObservers.append(
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                Task { @MainActor in
                    self?.attachMuteHandlers(to: controller)
                }
            }
        )

        for controller in GCController.controllers() {
            attachMuteHandlers(to: controller)
        }
    }

    func stopControllerMonitoring() {
        controllerObservers.forEach(NotificationCenter.default.removeObserver)
        controllerObservers.removeAll()
        isMonitoringControllers = false
    }

    private func attachMuteHandlers(to controller: GCController) {
        for (name, button) in controller.physicalInputProfile.buttons {
            let aliasText = Array(button.aliases).joined(separator: " ")
            let haystack = "\(name) \(aliasText) \(button.localizedName ?? "")".lowercased()
            guard haystack.contains("mute") else { continue }

            button.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in
                    self?.recordSecretPress()
                }
            }
        }
    }
}
