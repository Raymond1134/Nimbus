import SwiftUI

/// A self-centring virtual joystick.
/// Outputs normalised x/y values in the range -1 … 1.
/// Springs back to (0, 0) when the finger is lifted.
struct JoystickView: View {
    let label: String
    @Binding var x: Float   // -1 = left,  +1 = right
    @Binding var y: Float   // -1 = down,  +1 = up

    private let diameter: CGFloat = 130
    private var thumbRadius: CGFloat { 22 }
    private var trackRadius: CGFloat { diameter / 2 - thumbRadius }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1.5)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .frame(width: diameter, height: diameter)

                // Crosshair
                Group {
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: diameter - 10, height: 1)
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 1, height: diameter - 10)
                }

                // Thumb knob
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.9), Color.accentColor],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: thumbRadius * 2
                        )
                    )
                    .frame(width: thumbRadius * 2, height: thumbRadius * 2)
                    .shadow(color: Color.accentColor.opacity(0.5), radius: 6)
                    .offset(
                        x:  CGFloat(x) * trackRadius,
                        y: -CGFloat(y) * trackRadius   // SwiftUI Y is flipped
                    )
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        // Centre of the joystick in local coords
                        let centre = CGPoint(x: diameter / 2, y: diameter / 2)
                        let dx = value.location.x - centre.x
                        let dy = value.location.y - centre.y

                        // Clamp to the track circle
                        let distance = sqrt(dx * dx + dy * dy)
                        let clampedX = distance > trackRadius ? dx / distance * trackRadius : dx
                        let clampedY = distance > trackRadius ? dy / distance * trackRadius : dy

                        x =  Float(clampedX / trackRadius)
                        y = -Float(clampedY / trackRadius)   // invert Y
                    }
                    .onEnded { _ in
                        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.7)) {
                            x = 0
                            y = 0
                        }
                    }
            )

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
