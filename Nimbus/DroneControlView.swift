import SwiftUI
import CoreLocation

struct DroneControlView: View {
    @StateObject private var drone    = DroneState.shared
    @StateObject private var fc       = FlightControlManager.shared
    @StateObject private var wp       = WaypointManager.shared
    @StateObject private var ht       = HeadTrackingManager.shared

    // Alert
    @State private var alertTitle   = ""
    @State private var alertMessage = ""
    @State private var showAlert    = false

    // Gimbal tab
    @State private var gimbalTarget: Double = 0

    // Mission tab
    @State private var latString    = ""
    @State private var lonString    = ""
    @State private var altString    = "30"
    @State private var missionSpeed: Double = 5.0

    var body: some View {
        TabView {
            flyTab
                .tabItem { Label("Fly", systemImage: "airplane") }

            gimbalTab
                .tabItem { Label("Gimbal", systemImage: "camera.rotate") }

            missionTab
                .tabItem { Label("Mission", systemImage: "map") }

            headTrackTab
                .tabItem { Label("Head", systemImage: "airpodspro") }

            connectTab
                .tabItem { Label("Connect", systemImage: "cable.connector") }
        }
        .preferredColorScheme(.dark)
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - Helpers

    private func showStatus(_ title: String, _ message: String) {
        alertTitle   = title
        alertMessage = message
        showAlert    = true
    }

    private func handleResult(_ title: String, _ error: Error?) {
        showStatus(title, error?.localizedDescription ?? "Success")
    }
}

// MARK: - FLY TAB

extension DroneControlView {

    var flyTab: some View {
        VStack(spacing: 0) {

            // ── Video Feed ──────────────────────────────────────────────────
            ZStack(alignment: .top) {
                VideoFeedView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .background(Color.black)

                // HUD overlay
                HStack(spacing: 14) {
                    hudChip(icon: "battery.75percent",
                            text: "\(drone.batteryPercent)%",
                            color: drone.batteryPercent < 20 ? .red : .green)
                    hudChip(icon: "ruler",
                            text: String(format: "%.1f m", drone.altitudeMeters),
                            color: .white)
                    hudChip(icon: "location.fill",
                            text: "\(drone.gpsSatellites) sat",
                            color: drone.gpsSatellites < 6 ? .orange : .white)
                    hudChip(icon: "dot.radiowaves.left.and.right",
                            text: drone.flightMode,
                            color: .white)
                }
                .padding(8)

                if !drone.isConnected {
                    VStack {
                        Spacer()
                        Label("No drone connected", systemImage: "wifi.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.bottom, 6)
                    }
                }
            }

            Divider()

            // ── Speed Slider ────────────────────────────────────────────────
            VStack(spacing: 2) {
                HStack {
                    Image(systemName: "speedometer").foregroundStyle(.secondary)
                    Slider(value: $fc.maxSpeed, in: 0.5...10, step: 0.5) // Mini 2 max 10 m/s
                    Text(String(format: "%.1f m/s", fc.maxSpeed))
                        .monospacedDigit()
                        .frame(width: 58)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                Text("Max flight speed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)

            // ── Joysticks ───────────────────────────────────────────────────
            HStack {
                JoystickView(label: "Yaw · Throttle",
                             x: $fc.leftX,
                             y: $fc.leftY)
                Spacer()
                JoystickView(label: "Roll · Pitch",
                             x: $fc.rightX,
                             y: $fc.rightY)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            // ── Action Buttons ──────────────────────────────────────────────
            // Row 1 — motor + VS toggles
            HStack(spacing: 8) {
                actionButton("Arm", icon: "bolt.fill", tint: .yellow) {
                    fc.armMotors { handleResult("Arm Motors", $0) }
                }
                actionButton("Disarm", icon: "bolt.slash.fill", tint: .gray) {
                    fc.disarmMotors { handleResult("Disarm Motors", $0) }
                }
                actionButton(
                    fc.isVirtualStickEnabled ? "VS ON" : "VS OFF",
                    icon: fc.isVirtualStickEnabled ? "gamecontroller.fill" : "gamecontroller",
                    tint: fc.isVirtualStickEnabled ? .purple : .secondary
                ) {
                    toggleVirtualSticks()
                }
            }
            // Row 2 — flight
            HStack(spacing: 8) {
                actionButton("Takeoff", icon: "arrow.up.square.fill", tint: .green) {
                    fc.manualTakeoff { handleResult("Takeoff", $0) }
                }
                actionButton("Land", icon: "arrow.down.square.fill", tint: .orange) {
                    fc.vsLand { handleResult("Land", $0) }
                }
                actionButton("RTH", icon: "house.fill", tint: .blue) {
                    fc.returnToHome { handleResult("Return to Home", $0) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private func hudChip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func actionButton(
        _ title: String, icon: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }

    private func toggleVirtualSticks() {
        if fc.isVirtualStickEnabled {
            fc.disableVirtualSticks { handleResult("Virtual Sticks", $0) }
        } else {
            fc.enableVirtualSticks { handleResult("Virtual Sticks", $0) }
        }
    }
}

// MARK: - GIMBAL TAB

extension DroneControlView {

    var gimbalTab: some View {
        VStack(spacing: 24) {
            Text("Gimbal Pitch Control")
                .font(.headline)
                .padding(.top, 24)

            // Live readout
            HStack {
                Image(systemName: "camera.rotate")
                Text("Current pitch:")
                Text(String(format: "%.1f°", drone.gimbalPitchDegrees))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }

            // Vertical slider (rotated to feel like a physical tilt dial)
            VStack {
                Text("+20°  (up)").font(.caption).foregroundStyle(.secondary)
                Slider(value: $gimbalTarget, in: -90...20, step: 1)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 200)
                    .padding(.vertical, 80)
                    .onChange(of: gimbalTarget) { _, newValue in
                        fc.setGimbalPitch(newValue)
                    }
                Text("-90°  (nadir)").font(.caption).foregroundStyle(.secondary)
            }

            Text(String(format: "Target: %.0f°", gimbalTarget))
                .font(.title2)
                .monospacedDigit()

            // Quick-preset buttons
            HStack(spacing: 16) {
                gimbalPreset("Nadir\n-90°",  angle: -90)
                gimbalPreset("Level\n0°",    angle:   0)
                gimbalPreset("Up\n+20°",     angle:  20)
                gimbalPreset("Fwd\n-30°",    angle: -30)
            }
            .padding(.horizontal)

            Spacer()
        }
    }

    private func gimbalPreset(_ label: String, angle: Double) -> some View {
        Button {
            gimbalTarget = angle
            fc.setGimbalPitch(angle)
        } label: {
            Text(label)
                .multilineTextAlignment(.center)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - MISSION TAB

extension DroneControlView {

    var missionTab: some View {
        NavigationStack {
            Form {

                // ── Go-to point ─────────────────────────────────────────────
                Section("Fly To GPS Point") {
                    HStack {
                        Text("Latitude")
                        Spacer()
                        TextField("e.g. 37.7749", text: $latString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Longitude")
                        Spacer()
                        TextField("e.g. -122.4194", text: $lonString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Altitude (m)")
                        Spacer()
                        TextField("30", text: $altString)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Speed")
                        Slider(value: $missionSpeed, in: 1...10, step: 1)
                        Text("\(Int(missionSpeed)) m/s")
                            .frame(width: 44)
                    }

                    Button("Fly To Point") {
                        flyToPoint()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!drone.isConnected)
                }

                // ── Mission state ───────────────────────────────────────────
                Section("Mission State") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(wp.missionState)
                            .foregroundStyle(.secondary)
                    }
                    if wp.totalWaypoints > 0 {
                        HStack {
                            Text("Waypoint")
                            Spacer()
                            Text("\(wp.currentWaypointIndex + 1) / \(wp.totalWaypoints)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // ── Mission control ─────────────────────────────────────────
                Section("Mission Control") {
                    HStack(spacing: 12) {
                        Button("Pause") {
                            wp.pause { handleResult("Pause", $0) }
                        }
                        .buttonStyle(.bordered).tint(.orange)

                        Button("Resume") {
                            wp.resume { handleResult("Resume", $0) }
                        }
                        .buttonStyle(.bordered).tint(.green)

                        Button("Stop") {
                            wp.stop { handleResult("Stop", $0) }
                        }
                        .buttonStyle(.bordered).tint(.red)
                    }
                }

                // ── Safety endpoints ────────────────────────────────────────
                Section("Safety / Navigation Endpoints") {
                    Button("Return to Home") {
                        fc.returnToHome { handleResult("RTH", $0) }
                    }
                    Button("Cancel RTH") {
                        fc.cancelReturnToHome { handleResult("Cancel RTH", $0) }
                    }
                    Button("Set Home to Current Position") {
                        guard let coord = drone.homeCoordinate else {
                            showStatus("Set Home", "No GPS fix yet.")
                            return
                        }
                        fc.setHomeLocation(coord) { handleResult("Set Home", $0) }
                    }
                }

                // ── Current position ────────────────────────────────────────
                Section("Current Drone Position") {
                    HStack {
                        Text("Lat")
                        Spacer()
                        Text(String(format: "%.6f", drone.coordinate.latitude))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Lon")
                        Spacer()
                        Text(String(format: "%.6f", drone.coordinate.longitude))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Alt")
                        Spacer()
                        Text(String(format: "%.1f m", drone.altitudeMeters))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Mission")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func flyToPoint() {
        guard
            let lat = Double(latString),
            let lon = Double(lonString),
            let alt = Float(altString)
        else {
            showStatus("Invalid Input", "Enter valid numeric latitude, longitude, and altitude.")
            return
        }
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        wp.flyTo(coordinate: coord, altitude: alt, speed: Float(missionSpeed)) {
            handleResult("Fly To", $0)
        }
    }
}

// MARK: - HEAD TRACK TAB

extension DroneControlView {

    var headTrackTab: some View {
        NavigationStack {
            Form {

                // ── AirPods Status ──────────────────────────────────────────
                Section("AirPods") {
                    HStack {
                        Text("Sensor")
                        Spacer()
                        Label(
                            ht.isAvailable ? "Available" : "Not Available",
                            systemImage: ht.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundStyle(ht.isAvailable ? .green : .red)
                        .font(.caption)
                    }
                    HStack {
                        Text("AirPods")
                        Spacer()
                        Label(
                            ht.isConnected ? "Connected" : "Not Connected",
                            systemImage: ht.isConnected ? "airpodspro" : "airpodspro"
                        )
                        .foregroundStyle(ht.isConnected ? .green : .secondary)
                        .font(.caption)
                    }
                    HStack {
                        Text("Permission")
                        Spacer()
                        Text(ht.authStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Motion Active")
                        Spacer()
                        Text(ht.isTracking ? "Yes" : "No")
                            .foregroundStyle(ht.isTracking ? .green : .secondary)
                            .font(.caption)
                    }
                    if !ht.isAvailable {
                        Text("Requires AirPods Pro (1st/2nd gen), AirPods 3rd gen, AirPods 4 ANC, or AirPods Max.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // ── Enable & Align ──────────────────────────────────────────
                Section("Control") {
                    if !fc.isVirtualStickEnabled {
                        Text("Enable Virtual Sticks (VS) on the Fly tab first.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Toggle("Head Tracking Active", isOn: Binding(
                        get: { ht.isTracking },
                        set: { on in
                            if on { ht.startTracking() } else { ht.stopTracking() }
                        }
                    ))
                    .disabled(!ht.isAvailable || !fc.isVirtualStickEnabled)

                    Button {
                        ht.align()
                    } label: {
                        Label("Align to Current Head Position", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(!ht.isAvailable)

                    Text("Tip: sit or stand looking straight at your drone, then tap Align. This sets your neutral reference point. Tap Align again any time to re-centre.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // ── Live Head Angles ────────────────────────────────────────
                Section("Live Head Angles (relative to alignment)") {
                    headAngleRow("Pitch",
                                 value: ht.relPitch,
                                 icon: "arrow.up.and.down",
                                 meaning: ht.pitchToGimbal ? "→ Gimbal" : "→ Forward/Back")
                    headAngleRow("Yaw",
                                 value: ht.relYaw,
                                 icon: "arrow.left.and.right",
                                 meaning: ht.yawToDrone ? "→ Rotate" : "Inactive")
                    headAngleRow("Roll",
                                 value: ht.relRoll,
                                 icon: "arrow.clockwise",
                                 meaning: ht.rollToDrone ? "→ Strafe" : "Inactive")
                }

                // ── Axis Mapping ────────────────────────────────────────────
                Section("Axis Mapping") {
                    Picker("Head Pitch controls", selection: $ht.pitchToGimbal) {
                        Text("Gimbal tilt").tag(true)
                        Text("Fly forward/back").tag(false)
                    }
                    .pickerStyle(.segmented)

                    Toggle("Yaw → Rotate drone",   isOn: $ht.yawToDrone)
                    Toggle("Roll → Strafe drone",   isOn: $ht.rollToDrone)
                }

                // ── Sensitivity & Dead Zone ─────────────────────────────────
                Section("Tuning") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sensitivity")
                            Spacer()
                            Text(String(format: "%.2f×", ht.sensitivity)).monospacedDigit()
                        }
                        Slider(value: $ht.sensitivity, in: 0.25...2.0, step: 0.05)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Dead Zone")
                            Spacer()
                            Text(String(format: "±%.1f°", ht.deadZoneDeg)).monospacedDigit()
                        }
                        Slider(value: $ht.deadZoneDeg, in: 0...15, step: 0.5)
                        Text("Head movements smaller than this are ignored")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Pitch full-scale")
                            Spacer()
                            Text(String(format: "±%.0f°", ht.pitchMaxDeg)).monospacedDigit()
                        }
                        Slider(value: $ht.pitchMaxDeg, in: 10...60, step: 5)
                        Text("Head angle that produces maximum output")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Yaw full-scale")
                            Spacer()
                            Text(String(format: "±%.0f°", ht.yawMaxDeg)).monospacedDigit()
                        }
                        Slider(value: $ht.yawMaxDeg, in: 15...90, step: 5)
                    }
                }
            }
            .navigationTitle("Head Tracking")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func headAngleRow(_ label: String, value: Double, icon: String, meaning: String) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(label)
            Spacer()
            Text(meaning)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(String(format: "%+.1f°", value))
                .monospacedDigit()
                .foregroundStyle(abs(value) > 5 ? Color.accentColor : .secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

// MARK: - CONNECT TAB

extension DroneControlView {

    var connectTab: some View {
        NavigationStack {
            Form {

                // ── Product status ──────────────────────────────────────────
                Section("Product") {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(drone.isConnected ? Color.green : Color.red)
                                .frame(width: 10, height: 10)
                            Text(drone.isConnected
                                 ? drone.productName.isEmpty ? "Connected" : drone.productName
                                 : "Disconnected")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Flight Mode")
                        Spacer()
                        Text(drone.flightMode).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Battery")
                        Spacer()
                        Text("\(drone.batteryPercent)%")
                            .foregroundStyle(drone.batteryPercent < 20 ? .red : .secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("GPS Satellites")
                        Spacer()
                        Text("\(drone.gpsSatellites)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text("Altitude")
                        Spacer()
                        Text(String(format: "%.1f m", drone.altitudeMeters))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text("Flying")
                        Spacer()
                        Text(drone.isFlying ? "Yes" : "No").foregroundStyle(.secondary)
                    }
                }

                // ── Connection ──────────────────────────────────────────────
                Section("Connection") {
                    Text("Plug the RC into this device via USB-C, then tap Connect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Connect to RC / Drone") {
                        fc.startConnection()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Disconnect") {
                        fc.stopConnection()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                // ── RC Pairing ──────────────────────────────────────────────
                Section("RC Pairing") {
                    Text("Use this to pair a new remote controller with the Mavic Mini 2.\n1. Power on the drone.\n2. Hold the RC power button until the LED flashes rapidly.\n3. Tap Pair below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Pair Remote Controller") {
                        fc.pairRemoteController { message in
                            showStatus("RC Pairing", message)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }

                // ── Firmware versions ────────────────────────────────────────
                Section("Firmware") {
                    fwRow("Aircraft",   drone.aircraftFirmware)
                    fwRow("RC",         drone.rcFirmware)
                    fwRow("Camera",     drone.cameraFirmware)
                    fwRow("Gimbal",     drone.gimbalFirmware)
                    fwRow("Mobile SDK", drone.sdkVersion)
                }

                // ── Velocity readout ──────────────────────────────────────────
                Section("Velocities") {
                    velRow("North (X)", value: drone.velocityX)
                    velRow("East (Y)",  value: drone.velocityY)
                    velRow("Up (Z)",    value: drone.velocityZ)
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func fwRow(_ label: String, _ version: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(version.isEmpty ? "—" : version)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private func velRow(_ label: String, value: Float) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(format: "%+.2f m/s", value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
