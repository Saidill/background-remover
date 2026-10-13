import SwiftUI
import UniformTypeIdentifiers

struct Inspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch model.tool {
                case .background: BackgroundPanel(model: model)
                case .watermark: WatermarkPanel(model: model)
                }
                OutputPanel(model: model, number: model.tool == .background ? 3 : 5)
            }
            .padding(18)
        }
        .scrollIndicators(.never)
        .frame(width: 286)
        .background(Theme.panel)
        .disabled(model.source == nil)
        .opacity(model.source == nil ? 0.45 : 1)
    }
}

// MARK: - Background

private struct BackgroundPanel: View {
    @ObservedObject var model: EditorModel

    private let swatches: [(String, Color)] = [
        ("White", .white), ("Black", .black),
        ("ID Blue", Color(hex: 0x438EDB)), ("ID Red", Color(hex: 0xD0141C)),
        ("Gray", Color(hex: 0xE6E6E6)), ("Navy", Color(hex: 0x0F1D38)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(number: 1, title: "Background")
            SegmentedBar(options: EditorModel.BackgroundMode.allCases.map { ($0, $0.rawValue) },
                         selection: $model.mode)
            Text(hint).font(.system(size: 11)).foregroundStyle(Theme.sky.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            if model.mode == .color {
                HStack(spacing: 8) {
                    ColorSquares(colors: swatches, isSelected: { $0 == model.color }) { model.color = $0 }
                    ColorPicker("", selection: $model.color, supportsOpacity: false).labelsHidden().frame(width: 30)
                }
            }
        }

        if model.mode != .keep {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(number: 2, title: "Edge")
                FlatSlider(title: "Sharpness", value: $model.crisp, range: 1...4) { String(format: "%.1f", $0) }
                FlatSlider(title: "Trim halo", value: $model.trim, range: 0...0.4) { "\(Int($0 * 250))%" }
            }
        }
    }

    private var hint: String {
        switch model.mode {
        case .keep: return "Original background, untouched. Use with a watermark for documents."
        case .remove: return "Subject on transparency. JPEG sources export as PNG."
        case .color: return "Subject on a solid color."
        }
    }
}

// MARK: - Watermark

private struct WatermarkPanel: View {
    @ObservedObject var model: EditorModel
    @State private var fontFamilies: [String] = []

    private let colors: [(String, Color)] = [
        ("White", .white), ("Black", .black), ("Navy", Color(hex: 0x0F1D38)),
        ("Cobalt", Color(hex: 0x2E6BFF)), ("Red", Color(hex: 0xD0141C)), ("Gray", Color(hex: 0x8A8A8A)),
    ]

    private var wm: Binding<WatermarkSettings> { $model.watermark }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(number: 1, title: "Watermark")
            SegmentedBar(options: [(false, "Off"), (true, "On")], selection: wm.enabled)
        }

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(number: 2, title: "Text")
            TextField("Watermark text", text: wm.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1...4)
                .padding(8)
                .background(Theme.raised)
                .overlay(Rectangle().strokeBorder(Theme.line))
            HStack(spacing: 6) {
                fontMenu
                Button("B") { model.watermark.bold.toggle() }
                    .buttonStyle(OutlineButtonStyle(active: model.watermark.bold))
                    .help("Bold")
                Button("OUTLINE") { model.watermark.outline.toggle() }
                    .buttonStyle(OutlineButtonStyle(active: model.watermark.outline))
                    .help("Contrasting outline for busy backgrounds")
            }
        }
        .disabled(!model.watermark.enabled)

        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(number: 3, title: "Style")
            FlatSlider(title: "Size", value: wm.sizePercent, range: 1...30, step: 0.5) { String(format: "%.1f%%", $0) }
            FlatSlider(title: "Opacity", value: wm.opacity, range: 0.05...1, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
            FlatSlider(title: "Rotation", value: wm.rotation, range: -90...90, step: 1) { "\(Int($0))°" }
            HStack(spacing: 6) {
                ForEach([-45.0, 0, 30, 45, 90], id: \.self) { deg in
                    Button("\(Int(deg))°") { model.watermark.rotation = deg }
                        .buttonStyle(OutlineButtonStyle(active: model.watermark.rotation == deg))
                }
            }
            HStack(spacing: 8) {
                ColorSquares(colors: colors, isSelected: { c in
                    let ns = NSColor(c).usingColorSpace(.sRGB)
                    return ns.map { abs($0.redComponent - model.watermark.red) < 0.01
                        && abs($0.greenComponent - model.watermark.green) < 0.01
                        && abs($0.blueComponent - model.watermark.blue) < 0.01 } ?? false
                }) { setColor($0) }
                ColorPicker("", selection: Binding(
                    get: { Color(.sRGB, red: model.watermark.red, green: model.watermark.green, blue: model.watermark.blue) },
                    set: { setColor($0) }), supportsOpacity: false).labelsHidden().frame(width: 30)
            }
        }
        .disabled(!model.watermark.enabled)

        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(number: 4, title: "Placement")
            SegmentedBar(options: WatermarkSettings.Layout.allCases.map { ($0, $0.rawValue) }, selection: wm.layout)
            if model.watermark.layout == .single {
                HStack(alignment: .top, spacing: 16) {
                    AlignGrid(selected: model.currentAlign) { model.align($0) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AUTO-ALIGN").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Theme.sky)
                        Text("Pick a spot, or drag the text on the canvas. It snaps to center and margins.")
                            .font(.system(size: 11)).foregroundStyle(Theme.sky.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                FlatSlider(title: "Margin", value: wm.marginPercent, range: 0...15, step: 0.5) { String(format: "%.1f%%", $0) }
                    .onChange(of: model.watermark.marginPercent) { old, _ in realign(oldMargin: old) }
            } else {
                FlatSlider(title: "Spacing", value: wm.spacing, range: 0.2...4, step: 0.1) { String(format: "%.1f×", $0) }
            }
        }
        .disabled(!model.watermark.enabled)
        .onAppear {
            if fontFamilies.isEmpty { fontFamilies = NSFontManager.shared.availableFontFamilies }
        }
    }

    private var fontMenu: some View {
        Menu {
            ForEach(WatermarkSettings.builtInFonts, id: \.self) { f in
                Button(f) { model.watermark.fontName = f }
            }
            Divider()
            ForEach(fontFamilies, id: \.self) { f in
                Button(f) { model.watermark.fontName = f }
            }
        } label: {
            HStack {
                Text(model.watermark.fontName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Theme.paper)
            .padding(.horizontal, 8).frame(height: 26)
            .overlay(Rectangle().strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func setColor(_ c: Color) {
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
        model.watermark.red = ns.redComponent
        model.watermark.green = ns.greenComponent
        model.watermark.blue = ns.blueComponent
    }

    /// Keep an aligned watermark aligned when the margin changes.
    private func realign(oldMargin: Double) {
        guard let src = model.source else { return }
        var old = model.watermark
        old.marginPercent = oldMargin
        if let a = WatermarkAlign.allCases.first(where: { a in
            let c = WatermarkRenderer.center(for: a, old, imageSize: src.uprightSize)
            return abs(c.x - old.x) < 0.002 && abs(c.y - old.y) < 0.002
        }) { model.align(a) }
    }
}

/// 3 × 3 dot matrix for auto-align.
private struct AlignGrid: View {
    let selected: WatermarkAlign?
    let pick: (WatermarkAlign) -> Void

    var body: some View {
        let cases = WatermarkAlign.allCases
        VStack(spacing: 0) {
            ForEach(0..<3) { row in
                HStack(spacing: 0) {
                    ForEach(0..<3) { col in
                        let a = cases[row * 3 + col]
                        Button { pick(a) } label: {
                            Rectangle()
                                .fill(a == selected ? Theme.accent : Theme.sky.opacity(0.35))
                                .frame(width: a == selected ? 10 : 6, height: a == selected ? 10 : 6)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .background(
            Path { p in
                for i in 1..<3 {
                    let v = CGFloat(i) * 28
                    p.move(to: CGPoint(x: v, y: 0)); p.addLine(to: CGPoint(x: v, y: 84))
                    p.move(to: CGPoint(x: 0, y: v)); p.addLine(to: CGPoint(x: 84, y: v))
                }
            }.stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        )
        .overlay(Rectangle().strokeBorder(Theme.line))
        .frame(width: 84, height: 84)
    }
}

// MARK: - Output

private struct OutputPanel: View {
    @ObservedObject var model: EditorModel
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(number: number, title: "Output")
            Menu {
                Button("Automatic (\(model.autoType?.preferredFilenameExtension?.uppercased() ?? "—"))") {
                    model.formatChoice = nil
                }
                Divider()
                ForEach(model.formatChoices, id: \.identifier) { t in
                    Button(label(for: t)) { model.formatChoice = t }
                }
            } label: {
                HStack {
                    Text("FORMAT").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Theme.sky)
                    Spacer()
                    Text(model.outputType?.preferredFilenameExtension?.uppercased() ?? "—")
                        .font(Theme.mono(11, .bold)).foregroundStyle(Theme.paper)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.sky)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .overlay(Rectangle().strokeBorder(Theme.line))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)

            Text(note).font(.system(size: 11)).foregroundStyle(Theme.sky.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var note: String {
        guard let t = model.outputType else { return "" }
        return (t == .png || t == .tiff)
            ? "Lossless: unchanged pixels are bit-identical. Size, DPI, profile and metadata kept."
            : "Saved at maximum quality. Size, DPI, profile and metadata kept."
    }

    private func label(for t: UTType) -> String {
        let ext = t.preferredFilenameExtension?.uppercased() ?? t.identifier
        return (t == .png || t == .tiff) ? "\(ext) — lossless" : "\(ext) — max quality"
    }
}
