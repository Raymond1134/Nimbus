// ManualFlightControlView.swift — Nimbus
// Manual flight control debugging interface.
// Allows direct interaction with flight behaviors and virtual stick commands.
// For debugging purposes only.

import SwiftUI

struct ManualFlightControlView: View {

    @Environment(Orchestrator.self) private var orc

    @State private var pitch: Float = 0
    @State private var roll: Float = 0
    @State private var yaw: Float = 0
    @State private var throttle: Float = 0

    @State private var approachBoxInput = "0,0,1000,1000"
    @State private var approachStandoff = "3.0"
    @State private var approachMaxSec = "45.0"
    @State private var newSpotName = ""

    @State private var orbitRadius = "5.0"
    @State private var orbitDuration = "30.0"
    @State private var feedbackMessage = "No manual command sent yet."
    @State private var feedbackLevel: FeedbackLevel = .info
    @State private var feedbackTimestamp = Date()

    private enum FeedbackLevel {
        case info
        case success
        case error

        var color: Color {
            switch self {
            case .info: return .blue
            case .success: return .green
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                aircraftStatusSection
                feedbackSection
                takeoffLandSection
                rememberedSpotsSection
                directControlSection
                behaviorCommandsSection
                safetyLimitsSection
            }
            .navigationTitle("Manual Flight Control")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Feedback

    private var feedbackSection: some View {
        Section("Action Feedback") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: feedbackLevel.icon)
                    .foregroundStyle(feedbackLevel.color)
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 4) {
                    Text(feedbackMessage)
                        .font(.subheadline)
                    Text("Updated \(feedbackTimestamp.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Aircraft Status

    private var aircraftStatusSection: some View {
        Section("Aircraft Status") {
            HStack {
                Text("Connected")
                    .font(.subheadline)
                Spacer()
                Circle()
                    .fill(orc.bridge.isAircraftConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(orc.bridge.isAircraftConnected ? "Connected" : "Disconnected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(orc.bridge.isAircraftConnected ? .green : .red)
            }
            if orc.bridge.isAircraftConnected {
                let t = orc.bridge.telemetry
                HStack {
                    Text("Altitude")
                        .font(.subheadline)
                    Spacer()
                    Text("\(String(format: "%.1f", t.altitudeM)) m")
                        .font(.subheadline.monospacedDigit())
                }
                HStack {
                    Text("Battery")
                        .font(.subheadline)
                    Spacer()
                    Text("\(t.batteryPercent) %")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle((1..<20).contains(t.batteryPercent) ? .red : .primary)
                }
            }
        }
    }

    // MARK: - Takeoff / Landing

    private var takeoffLandSection: some View {
        Section("Flight State Control") {
            VStack(spacing: 12) {
                Button(action: takeoffCommand) {
                    Label {
                        Text("TAKEOFF")
                    } icon: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!orc.bridge.isAircraftConnected)

                Button(action: landCommand) {
                    Label {
                        Text("LAND")
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!orc.bridge.isAircraftConnected)

                Button(action: returnToHomeCommand) {
                    Label {
                        Text("RETURN TO HOME")
                    } icon: {
                        Image(systemName: "house.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!orc.bridge.isAircraftConnected)
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Direct Virtual Stick Control

    private var rememberedSpotsSection: some View {
        Section("Remembered Spots") {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name (optional)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Spot name", text: $newSpotName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }

                Button(action: saveCurrentSpot) {
                    Label {
                        Text("Save Current Spot")
                    } icon: {
                        Image(systemName: "mappin.and.ellipse")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(!orc.bridge.isAircraftConnected)

                if let currentLocation = orc.bridge.telemetry.currentLocation {
                    Text("Current: \(String(format: "%.6f", currentLocation.latitude)), \(String(format: "%.6f", currentLocation.longitude))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Current GPS location unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)

            if orc.rememberedSpots.isEmpty {
                Text("No saved spots yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(orc.rememberedSpots.enumerated()), id: \.offset) { _, spot in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(spot.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(spot.capturedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("\(String(format: "%.6f", spot.coordinate.latitude)), \(String(format: "%.6f", spot.coordinate.longitude))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button(action: { goToRememberedSpot(spot) }) {
                                Label("Go to spot", systemImage: "location.fill")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(!orc.bridge.isAircraftConnected)

                            Button(role: .destructive, action: { deleteRememberedSpot(spot) }) {
                                Image(systemName: "trash")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Button(role: .destructive, action: clearRememberedSpots) {
                    Label("Clear All Saved Spots", systemImage: "trash.slash")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var directControlSection: some View {
        Section("Direct Virtual Stick Control") {
            VStack(spacing: 16) {
                // Pitch slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Pitch (m/s)")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", pitch))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $pitch, in: -5...5, step: 0.1)
                        .tint(.blue)
                }

                // Roll slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Roll (m/s)")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", roll))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $roll, in: -5...5, step: 0.1)
                        .tint(.green)
                }

                // Yaw slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Yaw (deg/s)")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.1f", yaw))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $yaw, in: -90...90, step: 1)
                        .tint(.orange)
                }

                // Throttle slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Throttle (m/s)")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", throttle))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $throttle, in: -3...3, step: 0.1)
                        .tint(.purple)
                }

                // Send velocity button
                HStack(spacing: 10) {
                    Button(action: sendVelocity) {
                        Label {
                            Text("Send Command")
                        } icon: {
                            Image(systemName: "paperplane.fill")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!orc.bridge.isAircraftConnected)

                    Button(action: resetSliders) {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }

                // Hover button
                Button(action: hoverCommand) {
                    Label {
                        Text("HOVER (Zero All Axes)")
                    } icon: {
                        Image(systemName: "pause.circle.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!orc.bridge.isAircraftConnected)
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Behavior Commands

    private var behaviorCommandsSection: some View {
        Section("Flight Behaviors") {
            // Approach behavior
            VStack(spacing: 12) {
                Text("Approach (Visual Servo)")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Box [ymin,xmin,ymax,xmax]")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("0,0,1000,1000", text: $approachBoxInput)
                            .font(.caption.monospacedDigit())
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Standoff (m)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("3.0", text: $approachStandoff)
                            .font(.caption.monospacedDigit())
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Timeout (s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("45.0", text: $approachMaxSec)
                            .font(.caption.monospacedDigit())
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                    }
                }

                Button(action: startApproach) {
                    Label {
                        Text("Start Approach")
                    } icon: {
                        Image(systemName: "arrow.forward.circle.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(!orc.bridge.isAircraftConnected)
            }
            .padding(.vertical, 8)

            Divider()

            // Orbit behavior
            VStack(spacing: 12) {
                Text("Orbit (Horizontal Circle)")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Radius (m)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("5.0", text: $orbitRadius)
                            .font(.caption.monospacedDigit())
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Duration (s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("30.0", text: $orbitDuration)
                            .font(.caption.monospacedDigit())
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                    }
                }

                Button(action: startOrbit) {
                    Label {
                        Text("Start Orbit")
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!orc.bridge.isAircraftConnected)
            }
            .padding(.vertical, 8)

            Divider()

            // Person follow behavior
            VStack(spacing: 12) {
                Text("Person Follow")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: Binding(
                    get: { orc.isOverheadFollowModeEnabled },
                    set: { orc.isOverheadFollowModeEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Overhead Tracking")
                            .font(.subheadline)
                        Text(orc.isOverheadFollowModeEnabled
                             ? "Top-down above person (AirPods yaw-synced)"
                             : "Legacy heading-follow profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "AirPods Yaw/Pitch/Roll: %.1f / %.1f / %.1f°",
                                          orc.headTracking.effectiveAttitude.yawDeg,
                                          orc.headTracking.effectiveAttitude.pitchDeg,
                                          orc.headTracking.effectiveAttitude.rollDeg))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: "Drone-Head Yaw Δ: %.1f°",
                                          shortestAngleDelta(target: orc.headTracking.effectiveAttitude.yawDeg,
                                                            current: orc.bridge.telemetry.headingDeg)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button(action: startPersonFollow) {
                    Label {
                        Text("Start Person Follow")
                    } icon: {
                        Image(systemName: "figure.walk.motion")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
                .disabled(!orc.bridge.isAircraftConnected)
            }
            .padding(.vertical, 8)

            Divider()

            // Quick behavior buttons
            HStack(spacing: 10) {
                Button(action: stopCommand) {
                    Label {
                        Text("Stop Behavior")
                    } icon: {
                        Image(systemName: "stop.fill")
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(!orc.bridge.isAircraftConnected)

                Button(action: hoverCommand) {
                    Label {
                        Text("Hover")
                    } icon: {
                        Image(systemName: "pause.circle.fill")
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.yellow)
                .disabled(!orc.bridge.isAircraftConnected)
            }
        }
    }

    // MARK: - Safety Limits Display

    private var safetyLimitsSection: some View {
        Section("Safety Limits (Read-Only)") {
            // Display current limits
            row("Max Speed", "±2.0 m/s")
            row("Max Altitude", "30.0 m AGL")
            row("Min Standoff", "2.0 m")
            row("Dead-Man Switch", "0.3 s")
        }
    }

    // MARK: - Actions

    private func sendVelocity() {
        guard orc.bridge.isAircraftConnected else {
            print("❌ ManualFlightControl: Aircraft not connected")
            postFeedback("Cannot send velocity command: aircraft not connected.", level: .error)
            return
        }
        
        orc.bridge.sendVelocity(
            pitch: pitch,
            roll: roll,
            yaw: yaw,
            throttle: throttle
        )
        print("✈️  ManualFlightControl: Sent velocity [pitch=\(String(format: "%.2f", pitch))m/s, roll=\(String(format: "%.2f", roll))m/s, yaw=\(String(format: "%.1f", yaw))°/s, throttle=\(String(format: "%.2f", throttle))m/s]")
        postFeedback("Velocity sent: pitch \(String(format: "%.2f", pitch)) m/s, roll \(String(format: "%.2f", roll)) m/s, yaw \(String(format: "%.1f", yaw)) °/s, throttle \(String(format: "%.2f", throttle)) m/s.", level: .success)
    }

    private func hoverCommand() {
        guard orc.bridge.isAircraftConnected else {
            print("❌ ManualFlightControl: Aircraft not connected")
            postFeedback("Cannot hover: aircraft not connected.", level: .error)
            return
        }
        orc.bridge.sendHover()
        resetSliders()
        print("⏸️  ManualFlightControl: Hover command sent - all axes zeroed")
        postFeedback("Hover command sent. All axes set to zero.", level: .success)
    }

    private func stopCommand() {
        guard orc.bridge.isAircraftConnected else {
            print("❌ ManualFlightControl: Aircraft not connected")
            postFeedback("Cannot stop behavior: aircraft not connected.", level: .error)
            return
        }
        orc.behaviors.stop()
        resetSliders()
        print("⏹️  ManualFlightControl: Stop command sent - behavior halted")
        postFeedback("Behavior stopped and controls reset.", level: .success)
    }

    private func takeoffCommand() {
        guard orc.bridge.isAircraftConnected else {
            print("❌ ManualFlightControl: Aircraft not connected")
            postFeedback("Cannot take off: aircraft not connected.", level: .error)
            return
        }
        
        guard let aircraft = DJISDKManager.product() as? DJIAircraft else {
            print("❌ ManualFlightControl: Could not get aircraft reference")
            postFeedback("Takeoff failed: unable to access aircraft reference.", level: .error)
            return
        }
        
        guard let flightController = aircraft.flightController else {
            print("❌ ManualFlightControl: Could not get flight controller")
            postFeedback("Takeoff failed: flight controller unavailable.", level: .error)
            return
        }
        
        resetSliders()
        
        flightController.startTakeoff { error in
            if let error = error {
                print("❌ ManualFlightControl: Takeoff failed - \(error.localizedDescription)")
                Task { @MainActor in
                    postFeedback("Takeoff failed: \(error.localizedDescription)", level: .error)
                }
            } else {
                print("🚀 ManualFlightControl: Takeoff initiated - ascending to hover altitude")
                Task { @MainActor in
                    postFeedback("Takeoff initiated.", level: .success)
                }
            }
        }
    }

    private func landCommand() {
        guard orc.bridge.isAircraftConnected else {
            print("❌ ManualFlightControl: Aircraft not connected")
            postFeedback("Cannot land: aircraft not connected.", level: .error)
            return
        }
        
        guard let aircraft = DJISDKManager.product() as? DJIAircraft else {
            print("❌ ManualFlightControl: Could not get aircraft reference")
            postFeedback("Landing failed: unable to access aircraft reference.", level: .error)
            return
        }
        
        guard let flightController = aircraft.flightController else {
            print("❌ ManualFlightControl: Could not get flight controller")
            postFeedback("Landing failed: flight controller unavailable.", level: .error)
            return
        }
        
        resetSliders()
        
        flightController.startLanding { error in
            if let error = error {
                print("❌ ManualFlightControl: Landing failed - \(error.localizedDescription)")
                Task { @MainActor in
                    postFeedback("Landing failed: \(error.localizedDescription)", level: .error)
                }
            } else {
                print("📍 ManualFlightControl: Landing initiated - descending to ground")
                Task { @MainActor in
                    postFeedback("Landing initiated.", level: .success)
                }
            }
        }
    }

    private func returnToHomeCommand() {
        guard orc.bridge.isAircraftConnected else {
            print("❌ ManualFlightControl: Aircraft not connected")
            postFeedback("Cannot return home: aircraft not connected.", level: .error)
            return
        }
        
        guard let aircraft = DJISDKManager.product() as? DJIAircraft else {
            print("❌ ManualFlightControl: Could not get aircraft reference")
            postFeedback("Return to Home failed: unable to access aircraft reference.", level: .error)
            return
        }
        
        guard let flightController = aircraft.flightController else {
            print("❌ ManualFlightControl: Could not get flight controller")
            postFeedback("Return to Home failed: flight controller unavailable.", level: .error)
            return
        }
        
        resetSliders()
        
        flightController.startGoHome { error in
            if let error = error {
                print("❌ ManualFlightControl: Return to Home failed - \(error.localizedDescription)")
                Task { @MainActor in
                    postFeedback("Return to Home failed: \(error.localizedDescription)", level: .error)
                }
            } else {
                print("🏠 ManualFlightControl: Return to Home initiated - returning to launch point")
                Task { @MainActor in
                    postFeedback("Return to Home initiated.", level: .success)
                }
            }
        }
    }

    private func startApproach() {
        guard orc.bridge.isAircraftConnected else {
            print("❌ ManualFlightControl: Aircraft not connected")
            postFeedback("Cannot start approach: aircraft not connected.", level: .error)
            return
        }

        let boxStr = approachBoxInput.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard boxStr.count == 4 else {
            print("❌ ManualFlightControl: Invalid box format. Expected: ymin,xmin,ymax,xmax (e.g., 0,0,1000,1000)")
            postFeedback("Invalid approach box format. Use ymin,xmin,ymax,xmax (e.g. 0,0,1000,1000).", level: .error)
            return
        }

        let standoff = Double(approachStandoff) ?? 3.0
        let maxSec = Double(approachMaxSec) ?? 45.0
        guard standoff > 0, maxSec > 0 else {
            postFeedback("Approach parameters must be positive numbers.", level: .error)
            return
        }

        orc.behaviors.approach(box: boxStr, standoffM: standoff, maxSeconds: maxSec)
        print("🎯 ManualFlightControl: Approach started - box=\(boxStr), standoff=\(String(format: "%.1f", standoff))m, timeout=\(String(format: "%.1f", maxSec))s")
        postFeedback("Approach started (standoff \(String(format: "%.1f", standoff)) m, timeout \(String(format: "%.1f", maxSec)) s).", level: .success)
    }

    private func startOrbit() {
        guard orc.bridge.isAircraftConnected else {
            print("❌ ManualFlightControl: Aircraft not connected")
            postFeedback("Cannot start orbit: aircraft not connected.", level: .error)
            return
        }

        let radius = Double(orbitRadius) ?? 5.0
        let duration = Double(orbitDuration) ?? 30.0
        guard radius > 0, duration > 0 else {
            postFeedback("Orbit radius and duration must be positive numbers.", level: .error)
            return
        }

        orc.behaviors.orbit(radiusM: radius, durationSec: duration)
        print("⭕ ManualFlightControl: Orbit started - radius=\(String(format: "%.1f", radius))m, duration=\(String(format: "%.1f", duration))s (angular velocity: \(String(format: "%.1f", 360.0/duration))°/s)")
        postFeedback("Orbit started (radius \(String(format: "%.1f", radius)) m, duration \(String(format: "%.1f", duration)) s).", level: .success)
    }

    private func startPersonFollow() {
        guard orc.bridge.isAircraftConnected else {
            print("❌ ManualFlightControl: Aircraft not connected")
            postFeedback("Cannot start person follow: aircraft not connected.", level: .error)
            return
        }

        orc.startPersonFollow()
        print("👤 ManualFlightControl: Person follow started (mode: \(orc.isOverheadFollowModeEnabled ? "overhead" : "heading-follow"))")
        postFeedback("Person follow started (\(orc.isOverheadFollowModeEnabled ? "overhead" : "heading-follow") mode).", level: .success)
    }

    private func saveCurrentSpot() {
        let beforeCount = orc.rememberedSpots.count
        let proposedName = newSpotName.trimmingCharacters(in: .whitespacesAndNewlines)
        orc.saveRememberedSpot(name: proposedName.isEmpty ? nil : proposedName)
        if orc.rememberedSpots.count > beforeCount, let spot = orc.rememberedSpots.last {
            newSpotName = ""
            postFeedback("Saved spot '\(spot.name)'.", level: .success)
        } else {
            postFeedback("Failed to save spot. Ensure GPS location is available.", level: .error)
        }
    }

    private func goToRememberedSpot(_ spot: RememberedSpot) {
        guard orc.bridge.telemetry.currentLocation != nil else {
            postFeedback("Cannot navigate to '\(spot.name)' without a GPS fix.", level: .error)
            return
        }
        orc.returnToRememberedSpot(spot)
        postFeedback("Navigating to saved spot '\(spot.name)'.", level: .success)
    }

    private func deleteRememberedSpot(_ spot: RememberedSpot) {
        guard let index = orc.rememberedSpots.firstIndex(of: spot) else { return }
        orc.deleteRememberedSpots(at: IndexSet(integer: index))
        postFeedback("Deleted saved spot '\(spot.name)'.", level: .info)
    }

    private func clearRememberedSpots() {
        orc.clearRememberedSpots()
        postFeedback("Cleared all saved spots.", level: .info)
    }

    private func resetSliders() {
        pitch = 0
        roll = 0
        yaw = 0
        throttle = 0
    }

    // MARK: - Helper

    @ViewBuilder
    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func postFeedback(_ message: String, level: FeedbackLevel) {
        feedbackMessage = message
        feedbackLevel = level
        feedbackTimestamp = Date()
    }

    private func shortestAngleDelta(target: Double, current: Double) -> Double {
        (target - current + 540).truncatingRemainder(dividingBy: 360) - 180
    }
}

#Preview {
    ManualFlightControlView()
        .environment(Orchestrator())
}
