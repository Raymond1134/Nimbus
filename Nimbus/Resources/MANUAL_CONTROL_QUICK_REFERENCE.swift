/// MANUAL FLIGHT CONTROL QUICK REFERENCE
/// ═══════════════════════════════════════════════════════════════════════════
///
/// QUICK START
/// ══════════
/// 1. Connect drone
/// 2. Debug tab → Manual Flight Control → Flight Control Panel
/// 3. Adjust sliders and tap "Send Command"
///
/// ═══════════════════════════════════════════════════════════════════════════
///
/// DIRECT VELOCITY SLIDERS
/// ══════════════════════════════════════════════════════════════════════════
/// ┌─────────────────────────────────────────────────────────────────────────┐
/// │ PITCH (m/s)           │ Forward (+) / Backward (-)     │ Range: ±5.0  │
/// │ ROLL (m/s)            │ Right (+) / Left (-)            │ Range: ±5.0  │
/// │ YAW (deg/s)           │ Clockwise (+) rotation         │ Range: ±90   │
/// │ THROTTLE (m/s)        │ Up (+) / Down (-)              │ Range: ±3.0  │
/// └─────────────────────────────────────────────────────────────────────────┘
///
/// Safety limits (enforced by SafetySupervisor):
///   • Max velocity on any axis: 2.0 m/s
///   • Max yaw rate: 45 deg/s
///   • All commands are clamped before sending to aircraft
///
/// ═══════════════════════════════════════════════════════════════════════════
///
/// BUTTON REFERENCE
/// ═══════════════════════════════════════════════════════════════════════════
/// ┌──────────────────────┬─────────────────────────┬────────────────────────┐
/// │ SEND COMMAND         │ Executes current sliders│ Passes through safety  │
/// ├──────────────────────┼─────────────────────────┼────────────────────────┤
/// │ RESET (↻)            │ Zeros all sliders       │ Non-destructive        │
/// ├──────────────────────┼─────────────────────────┼────────────────────────┤
/// │ HOVER (EMERGENCY)    │ Stops everything NOW    │ Zeros all axes         │
/// ├──────────────────────┼─────────────────────────┼────────────────────────┤
/// │ START APPROACH       │ Visual servo to target  │ Uses bbox parameters   │
/// ├──────────────────────┼─────────────────────────┼────────────────────────┤
/// │ START ORBIT          │ Horizontal circle       │ Uses radius & duration │
/// ├──────────────────────┼─────────────────────────┼────────────────────────┤
/// │ STOP                 │ Halt behavior + hover   │ Cancels current mode   │
/// ├──────────────────────┼─────────────────────────┼────────────────────────┤
/// │ LAND                 │ Controlled landing      │ DJI SDK routine        │
/// ├──────────────────────┼─────────────────────────┼────────────────────────┤
/// │ RTH                  │ Return to home point    │ DJI SDK routine        │
/// └──────────────────────┴─────────────────────────┴────────────────────────┘
///
/// ═══════════════════════════════════════════════════════════════════════════
///
/// APPROACH BEHAVIOR
/// ═════════════════════════════════════════════════════════════════════════
/// 
/// Visual servo toward target. Stops when bbox reaches target size.
///
/// Configuration:
///   • Box: "ymin,xmin,ymax,xmax" in 0-1000 range
///     Examples:
///       "0,0,1000,1000"       ← Full frame
///       "200,200,800,800"     ← Center 60%
///       "400,400,600,600"     ← Center 20%
///
///   • Standoff: Distance to stop at (3.0 m default)
///   • Timeout: Max time before auto-abort (45 s default)
///
/// Expected behavior:
///   1. Moves toward target (box gets larger)
///   2. Adjusts left/right if off-center
///   3. Adjusts up/down if vertically offset
///   4. Stops when box area = target area
///   5. Or stops if timeout reached
///
/// ═══════════════════════════════════════════════════════════════════════════
///
/// ORBIT BEHAVIOR
/// ═════════════════════════════════════════════════════════════════════════
///
/// Horizontal circle pattern at current altitude.
///
/// Configuration:
///   • Radius: 5.0 m (default safe distance)
///   • Duration: 30.0 s (one full circle)
///     Angular rate = 360 / Duration degrees/second
///     Examples:
///       Duration 30 s → 12 deg/s (slow)
///       Duration 15 s → 24 deg/s (medium)
///       Duration 10 s → 36 deg/s (fast)
///
/// Expected behavior:
///   1. Drone rolls inward slightly
///   2. Maintains altitude (+0 throttle)
///   3. Yaws at constant rate
///   4. Completes one full circle
///   5. Auto-stops and idles
///
/// ═══════════════════════════════════════════════════════════════════════════
///
/// SYSTEM STATUS INDICATORS
/// ═════════════════════════════════════════════════════════════════════════
///
/// Status Bar (top of OperationalView):
///   🟢 Drone Connected / 🔴 No Aircraft
///   Battery %  |  Altitude  |  GPS Satellites
///   🟢 Backend reachable  |  🔴 Backend down
///
/// Debug Tab shows:
///   • Altitude (red ⚠ if > 30m)
///   • Battery (red ⚠ if < 20%)
///   • GPS (orange ⚠ if no fix)
///
/// ═══════════════════════════════════════════════════════════════════════════
///
/// EMERGENCY ABORT PROCEDURE
/// ═════════════════════════════════════════════════════════════════════════
///
/// Priority order:
///   1. Tap "HOVER (Emergency Stop)" in Manual Flight Control
///   2. If no response, tap "ABORT" in Operational tab
///   3. If still unresponsive, use physical RC to recover
///   4. Last resort: Catch drone or allow battery drain
///
/// Note: Dead-man's switch will auto-hover if no command for 0.3s
///
/// ═══════════════════════════════════════════════════════════════════════════
///
/// COMMON TUNING TESTS
/// ═══════════════════════════════════════════════════════════════════════════
///
/// Test 1: Pitch Response (1.0 m/s)
///   Observe: Acceleration, smoothness, stability
///   Adjust: kFwd in FlightBehaviors.swift line 145
///
/// Test 2: Roll Response (1.0 m/s)  
///   Observe: Bank angle, recovery speed
///   Adjust: Similar P-controller gains
///
/// Test 3: Vertical Response (1.0 m/s throttle)
///   Observe: Acceleration, climb rate, lag
///   Adjust: kVert in FlightBehaviors.swift line 147
///
/// Test 4: Approach Accuracy
///   Set bbox to known target region
///   Measure: How close does it get? Any overshooting?
///   Adjust: kFwd, kYaw, kVert gains
///
/// Test 5: Orbit Dynamics
///   Compare measured circle time to configured duration
///   If slower: increase lateral roll command (line 165)
///   If faster: decrease roll command
///
/// ═══════════════════════════════════════════════════════════════════════════
///
/// DEBUGGING WITH XCODE CONSOLE
/// ═════════════════════════════════════════════════════════════════════════
///
/// Look for these log prefixes:
///   [ManualFlightControl]   ← Your commands
///   [Orchestrator]          ← State machine lifecycle
///   [FlightBehaviors]       ← Behavior execution
///   [DJISDKBridge]          ← Low-level SDK
///
/// Useful logs:
///   "Sent velocity" → Confirms command was executed
///   "Aircraft disconnected" → Connection was lost
///   "Behavior complete" → Approach/orbit finished
///   "Dead-man switch activated" → No command for 0.3s
///
/// ═══════════════════════════════════════════════════════════════════════════
