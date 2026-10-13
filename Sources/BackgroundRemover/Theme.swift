import SwiftUI

/// "Blueprint workbench": navy drafting paper, cobalt ink, hairlines. Flat — no gradients or glow.
enum Theme {
    static let ink = Color(hex: 0x0A1428)      // window
    static let panel = Color(hex: 0x0F1D38)    // rails, inspector
    static let raised = Color(hex: 0x162A4F)   // fields, hover
    static let line = Color(hex: 0x24406E)     // hairlines
    static let gridMinor = Color(hex: 0x13254A)
    static let gridMajor = Color(hex: 0x1B3361)
    static let accent = Color(hex: 0x2E6BFF)   // cobalt
    static let sky = Color(hex: 0x8FB8FF)      // secondary text, guides
    static let paper = Color(hex: 0xEAF1FF)    // primary text
    static let checkA = Color(hex: 0x1A2D55)
    static let checkB = Color(hex: 0x223A6B)

    static func label(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .heavy) }
    static func mono(_ size: CGFloat = 11, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

// MARK: - Reusable flat controls

/// "01 ─ BACKGROUND ────────"
struct SectionHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", number)).font(Theme.mono(10, .bold)).foregroundStyle(Theme.accent)
            Text(title.uppercased()).font(Theme.label()).tracking(1.6).foregroundStyle(Theme.sky)
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

struct SegmentedBar<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                let selected = opt.0 == selection
                Button { selection = opt.0 } label: {
                    Text(opt.1.uppercased())
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .foregroundStyle(selected ? Color.white : Theme.sky)
                        .background(selected ? Theme.accent : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < options.count - 1 { Rectangle().fill(Theme.line).frame(width: 1, height: 28) }
            }
        }
        .overlay(Rectangle().strokeBorder(Theme.line))
    }
}

/// Thin track, square handle, monospaced value readout.
struct FlatSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Theme.sky)
                Spacer()
                Text(format(value)).font(Theme.mono(11, .medium)).foregroundStyle(Theme.paper)
            }
            GeometryReader { g in
                let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.line).frame(height: 2)
                    Rectangle().fill(Theme.accent).frame(width: max(0, frac * g.size.width), height: 2)
                    Rectangle().fill(Theme.paper).frame(width: 10, height: 10)
                        .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 2))
                        .offset(x: frac * (g.size.width - 10))
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let t = Double(min(1, max(0, v.location.x / g.size.width)))
                    var nv = range.lowerBound + t * (range.upperBound - range.lowerBound)
                    if step > 0 { nv = (nv / step).rounded() * step }
                    value = min(range.upperBound, max(range.lowerBound, nv))
                })
            }
            .frame(height: 14)
        }
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold)).tracking(1)
            .padding(.horizontal, 10).frame(height: 26)
            .foregroundStyle(active ? Color.white : Theme.paper)
            .background(active ? Theme.accent : (configuration.isPressed ? Theme.raised : Color.clear))
            .overlay(Rectangle().strokeBorder(active ? Theme.accent : Theme.line))
            .contentShape(Rectangle())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .heavy)).tracking(1.4)
            .padding(.horizontal, 16).frame(height: 30)
            .foregroundStyle(.white)
            .background(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35))
            .contentShape(Rectangle())
    }
}

struct ColorSquares: View {
    let colors: [(String, Color)]
    let isSelected: (Color) -> Bool
    let pick: (Color) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.0) { name, c in
                Button { pick(c) } label: {
                    Rectangle().fill(c).frame(width: 22, height: 22)
                        .overlay(Rectangle().strokeBorder(Theme.line))
                        .padding(2)
                        .overlay(Rectangle().strokeBorder(isSelected(c) ? Theme.accent : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(name)
            }
        }
    }
}

/// Crop marks around a rect — the recurring blueprint motif.
struct CropMarks: Shape {
    var length: CGFloat = 14
    var gap: CGFloat = 6

    func path(in r: CGRect) -> Path {
        var p = Path()
        for (x, y, dx, dy) in [(r.minX, r.minY, -1.0, -1.0), (r.maxX, r.minY, 1.0, -1.0),
                               (r.minX, r.maxY, -1.0, 1.0), (r.maxX, r.maxY, 1.0, 1.0)] {
            p.move(to: CGPoint(x: x + dx * gap, y: y)); p.addLine(to: CGPoint(x: x + dx * (gap + length), y: y))
            p.move(to: CGPoint(x: x, y: y + dy * gap)); p.addLine(to: CGPoint(x: x, y: y + dy * (gap + length)))
        }
        return p
    }
}

/// The app's mark: a square inside crop marks.
struct LogoMark: View {
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Rectangle().fill(Theme.accent).frame(width: size * 0.5, height: size * 0.5)
            CropMarks(length: size * 0.28, gap: size * 0.08)
                .stroke(Theme.paper, lineWidth: 1.5)
                .frame(width: size * 0.5, height: size * 0.5)
        }
        .frame(width: size, height: size)
    }
}
