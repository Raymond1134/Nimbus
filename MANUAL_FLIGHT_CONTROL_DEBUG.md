// MANUAL FLIGHT CONTROL DEBUG GUIDE
// ═══════════════════════════════════════════════════════════════════════════
//
// This document explains how to use the new Manual Flight Control debugging
// interface added to the Nimbus app for testing and tuning flight behaviors.
//
// IMPORTANT: This is for DEBUGGING PURPOSES ONLY. Manual flight control is not
// part of the intended operational behavior of the system.

// SECTION 1: ACCESSING THE MANUAL CONTROL PANEL
// ═══════════════════════════════════════════════════════════════════════════
//
// 1. Launch the Nimbus app on your iOS device or simulator
// 2. Navigate to the "Debug" tab (wrench icon)
// 3. Once an aircraft is connected, you'll see a new section:
//    "Manual Flight Control (DEBUG)"
// 4. Tap "Flight Control Panel" to open the full control interface
//
// NOTE: The manual control panel is disabled until you connect an aircraft.

// SECTION 2: DIRECT VIRTUAL STICK CONTROL
// ═══════════════════════════════════════════════════════════════════════════
//
// The top section allows direct control of the Virtual Stick axes via sliders:
//
// • PITCH (m/s):        Forward/backward velocity (-5.0 to +5.0 m/s)
// • ROLL (m/s):         Left/right velocity (-5.0 to +5.0 m/s)
// • YAW (deg/s):         Rotation rate (-90 to +90 deg/s)
// • THROTTLE (m/s):      Up/down velocity (-3.0 to +3.0 m/s)
//
// Steps to send a command:
// 1. Adjust all four sliders to desired values
// 2. Tap "Send Command" button
// 3. The drone will execute that velocity command
// 4. All commands pass through SafetySupervisor clamping
//
// To reset all sliders to zero:
// • Tap the circular arrow button next to "Send Command"
//
// Emergency stop (all axes to zero):
// • Tap "HOVER (Emergency Stop)" button
// • This immediately stops all motion and hovers in place
// • Overrides any active behavior
//
// Differences:
// • "Send Command" - sends the exact values you set
// • "HOVER" - zeros all axes for immediate stop + safety engagement
// • "Stop" - stops executing behavior and hovers

// SECTION 3: FLIGHT BEHAVIORS
// ═══════════════════════════════════════════════════════════════════════════
//
// APPROACH (Visual Servo)
// ───────────────────────
// Drives toward a target using bounding box area as distance proxy
//
// Parameters:
// • Box [ymin,xmin,ymax,xmax]: Vision bounding box in 0-1000 range
//   - ymin, ymax: vertical position (0=top, 1000=bottom)
//   - xmin, xmax: horizontal position (0=left, 1000=right)
//   - Default: "0,0,1000,1000" (full frame)
//   - Example for center: "300,300,700,700"
//
// • Standoff (m): Desired distance from target at completion
//   - Default: 3.0 m
//   - Safe range: 2.0 - 10.0 m
//
// • Timeout (s): Maximum time to spend on approach
//   - Default: 45.0 s
//   - Behavior auto-stops if timeout reached
//
// To test:
// 1. Configure bounding box and standoff
// 2. Tap "Start Approach"
// 3. Monitor the drone's movement toward the box
// 4. Behavior completes when box area matches target area, or timeout
//
// Use case: Test grounding and visual servo tuning
// Debug tip: Adjust bboxes manually to see how the controller responds
//
//
// ORBIT (Horizontal Circle)
// ─────────────────────────
// Maintains a horizontal circular pattern around current position
//
// Parameters:
// • Radius (m): Distance from center point
//   - Default: 5.0 m
//   - Safe range: 2.0 - 15.0 m
//
// • Duration (s): Time to complete one full orbit
//   - Default: 30.0 s
//   - Angular rate = 360 / duration degrees/second
//   - Example: 30s = 12 deg/s
//
// To test:
// 1. Get drone airborne
// 2. Set radius and duration
// 3. Tap "Start Orbit"
// 4. Drone completes one circle, then returns to idle
//
// Use case: Test roll/yaw control dynamics
// Debug tip: Vary duration to test different angular velocities
//
//
// QUICK COMMANDS
// ──────────────
// • STOP:   Halts current behavior, hovers in place
// • LAND:   Initiates landing routine via DJI SDK
// • RTH:    Return to Home via DJI SDK

// SECTION 4: SAFETY LIMITS (Read-Only)
// ═══════════════════════════════════════════════════════════════════════════
//
// This read-only section shows the current safety constraints:
//
// • Max Speed:         ±2.0 m/s (all velocity axes)
// • Max Altitude:      30.0 m AGL
// • Min Standoff:      2.0 m (minimum distance from target)
// • Geofence Radius:   50.0 m (search bound from home point)
// • Dead-Man Switch:   0.3 s (max time between commands before hover)
//
// Current Aircraft State (when connected):
// • Altitude:          Current height above ground
// • Battery:           Battery percentage (red warning below 20%)
// • GPS:               GPS fix status and satellite count
//
// NOTE: These limits are enforced by SafetySupervisor before every command.
//       All velocity commands are automatically clamped to these limits.
//       To change limits, edit SafetySupervisor.swift

// SECTION 5: DEBUG WORKFLOW EXAMPLES
// ═══════════════════════════════════════════════════════════════════════════
//
// EXAMPLE 1: Tuning Direct Velocity Control
// ──────────────────────────────────────────
// Goal: Find optimal pitch gain for smooth forward flight
//
// 1. Set Pitch to 1.0 m/s, all others to 0
// 2. Tap "Send Command" and observe drone response
// 3. Document the result: acceleration, smoothness, overshooting, etc.
// 4. Adjust Pitch to 0.5 and retry
// 5. Compare results to tune
// 6. Once satisfied, modify FlightBehaviors.swift gain constants
//
//
// EXAMPLE 2: Testing Approach Behavior
// ─────────────────────────────────────
// Goal: Verify visual servo works with a synthetic bbox
//
// 1. Get drone airborne and pointed at a target
// 2. Note the center of the target in the camera feed
// 3. Estimate a bounding box: e.g., "200,200,800,800"
// 4. Set Standoff to 3.0 m
// 5. Tap "Start Approach"
// 6. Watch the approach execution in the Debug log
// 7. Monitor: "areaErr", "latErr", "vertErr" to see feedback signals
// 8. Verify drone stops at proper distance
// 9. Adjust box or standoff and retry
//
//
// EXAMPLE 3: Roll/Yaw Dynamics Testing
// ──────────────────────────────────────
// Goal: Verify orbit behavior has correct angular velocity
//
// 1. Get drone airborne at 10m altitude
// 2. Set Orbit Duration to 30.0 s (12 deg/s)
// 3. Tap "Start Orbit"
// 4. Use a stopwatch to measure actual time for one circle
// 5. Compare to expected 30 seconds
// 6. If off, check roll/yaw gains in FlightBehaviors.swift
// 7. Try Duration = 60.0 s (6 deg/s) and verify slower rotation
//
//
// EXAMPLE 4: Velocity Clamping Verification
// ───────────────────────────────────────────
// Goal: Confirm that SafetySupervisor limits are enforced
//
// 1. Set Pitch to 10.0 m/s (exceeds max of 2.0)
// 2. Set Roll to -8.0 m/s (exceeds max of 2.0)
// 3. Tap "Send Command"
// 4. Check console output:
//    - Display shows "10.0" and "-8.0" (your input)
//    - Actual command sent is clamped to ±2.0
// 5. Observe that drone moves at max safe speed, not your input

// SECTION 6: DEBUGGING TIPS
// ═══════════════════════════════════════════════════════════════════════════
//
// • Console Logging: All manual commands print to Xcode console
//   Look for "ManualFlightControl:" prefix
//
// • Behavior Execution State: Check Orchestrator logs for behavior lifecycle
//   Look for "Behavior complete → idle"
//
// • Safety Rejections: If a command doesn't work, check:
//   1. Is aircraft connected? (green dot in status bar)
//   2. Is battery above 10%? (red warning threshold)
//   3. Is altitude below ceiling? (30m default)
//   4. Did SafetySupervisor clamp the command?
//
// • Tuning Parameters: To adjust behavior gains:
//   1. Edit FlightBehaviors.swift (lines 145-151 for approach)
//   2. Recompile and test
//   3. Compare results to baseline
//
// • Recording Test Sessions: Use Xcode's console to log results
//   • Note timestamp, parameters, and outcome
//   • Build a tuning spreadsheet for reference
//
// • Real World vs Simulation: Test in both environments
//   • Simulator: No wind, instant response
//   • Real drone: Wind, latency, battery drain

// SECTION 7: KNOWN LIMITATIONS
// ═══════════════════════════════════════════════════════════════════════════
//
// • No Joystick UI: Controls are slider-based, not analog joystick
//   Future: Could add SwiftUI gesture-based virtual joystick
//
// • No Real-time Telemetry Plot: Can't graph velocity/altitude over time
//   Future: Could add Core Metrics integration
//
// • Approach requires valid bbox: If bbox is off-frame, approach won't work
//   Manual entry needed; consider vision overlay in future
//
// • No persistent tuning presets: Settings reset on app restart
//   Future: Could save presets to UserDefaults or cloud

// SECTION 8: EMERGENCY PROCEDURES
// ═══════════════════════════════════════════════════════════════════════════
//
// If drone behavior seems erratic:
//
// 1. IMMEDIATE: Tap "HOVER (Emergency Stop)"
// 2. Verify all sliders are at zero
// 3. Watch for drone to stabilize
// 4. If still erratic, tap "ABORT" on Operational tab
// 5. If still not responding, use physical RC (if available)
// 6. Last resort: Allow battery drain or catch the drone
//
// If app crashes during manual control:
// • Drone will hover automatically (dead-man's switch)
// • Wait 30 seconds for auto-hover to engage if needed
// • Restart app and reconnect

// ═══════════════════════════════════════════════════════════════════════════
// Questions? Refer to FlightBehaviors.swift, DJISDKBridge.swift, and
// SafetySupervisor.swift for implementation details.
// ═══════════════════════════════════════════════════════════════════════════
