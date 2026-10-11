import SwiftUI

/// Fan response for the control sheet: the configured curve plus the live operating point.
struct CurvePreview: View {
    let minimumRPM: Int
    let maximumRPM: Int
    let start: Double
    let maximum: Double
    /// Set in constant mode: the curve becomes a flat line at this speed.
    let constant: Double?
    /// The fan's measured speed, plotted against the sensor temperature.
    let rpm: Int
    let current: Double?
    let range: ClosedRange<Double>
    let unit: String
    var body: some View {
        VStack(spacing: 4) {
            HStack { Text("\(maximumRPM) RPM"); Spacer(); Text(constant == nil ? "\(start, specifier: "%.0f")\(unit) → \(maximum, specifier: "%.0f")\(unit)" : "") }
            GeometryReader { geometry in
                let width = geometry.size.width, height = geometry.size.height
                let x = { (t: Double) in width * max(0, min(1, (t - range.lowerBound) / (range.upperBound - range.lowerBound))) }
                let y = { (r: Double) in height * (1 - max(0, min(1, (r - Double(minimumRPM)) / Double(max(1, maximumRPM - minimumRPM))))) }
                Path { path in
                    if let constant {
                        path.move(to: CGPoint(x: 0, y: y(constant))); path.addLine(to: CGPoint(x: width, y: y(constant)))
                    } else {
                        path.move(to: CGPoint(x: 0, y: height))
                        path.addLine(to: CGPoint(x: x(start), y: height))
                        path.addLine(to: CGPoint(x: x(maximum), y: 0))
                        path.addLine(to: CGPoint(x: width, y: 0))
                    }
                }.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    .animation(.easeOut(duration: 0.2), value: constant)
                if let current {
                    Path { path in
                        path.move(to: CGPoint(x: x(current), y: 0)); path.addLine(to: CGPoint(x: x(current), y: height))
                    }.stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 1.5))
                        .position(x: x(current), y: y(Double(rpm)))
                        .animation(.easeInOut(duration: 0.6), value: rpm)
                    Text("\(current, specifier: "%.0f")\(unit) · \(rpm) RPM").monospacedDigit().foregroundStyle(.orange)
                        .fixedSize()
                        .position(x: min(max(x(current), 50), width - 50), y: y(Double(rpm)) > height / 2 ? y(Double(rpm)) - 12 : y(Double(rpm)) + 12)
                }
            }
            HStack { Text("\(minimumRPM) RPM"); Spacer() }
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(10).background(Color.primary.opacity(0.035)).cornerRadius(5)
    }
}
