import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @State private var isDropTargeted = false
    @State private var loupeOn = true
    @State private var cursor: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ProgressLine(active: model.isBusy)
            HStack(spacing: 0) {
                toolRail
                Rectangle().fill(Theme.line).frame(width: 1)
                canvas
                Rectangle().fill(Theme.line).frame(width: 1)
                Inspector(model: model)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            statusBar
        }
        .background(Theme.ink)
        .foregroundStyle(Theme.paper)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .frame(minWidth: 1040, minHeight: 680)
        .ignoresSafeArea(.container, edges: .top)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert("Couldn't finish", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            LogoMark()
            Text("CUTOUT").font(.system(size: 13, weight: .black)).tracking(3)
            Text("/ BACKGROUND & WATERMARK").font(Theme.mono(9)).foregroundStyle(Theme.sky)

            Spacer()
            if let src = model.source {
                Text(src.url.lastPathComponent).font(Theme.mono(11)).foregroundStyle(Theme.sky).lineLimit(1)
            }
            Spacer()

            Button("OPEN") { model.chooseFile() }
                .buttonStyle(OutlineButtonStyle())
                .keyboardShortcut("o")
            Button { model.save() } label: {
                HStack(spacing: 6) {
                    Text("EXPORT")
                    Image(systemName: "arrow.down.to.line").font(.system(size: 10, weight: .heavy))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut("s")
            .disabled(model.source == nil || model.isBusy || model.afterImage == nil)
        }
        .padding(.leading, 84) // window traffic lights
        .padding(.trailing, 14)
        .frame(height: 46)
        .background(Theme.panel)
    }

    // MARK: Tool rail

    private var toolRail: some View {
        VStack(spacing: 4) {
            railButton(.background, icon: "scissors", label: "BG")
            railButton(.watermark, icon: "textformat", label: "MARK")
            Spacer()
        }
        .padding(.top, 10)
        .frame(width: 56)
        .background(Theme.panel)
    }

    private func railButton(_ tool: EditorModel.Tool, icon: String, label: String) -> some View {
        let selected = model.tool == tool
        return Button { model.tool = tool } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                Text(label).font(Theme.mono(8, .bold)).tracking(1)
            }
            .foregroundStyle(selected ? Theme.paper : Theme.sky.opacity(0.7))
            .frame(width: 56, height: 52)
            .background(selected ? Theme.raised : Color.clear)
            .overlay(alignment: .leading) {
                Rectangle().fill(selected ? Theme.accent : .clear).frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.rawValue)
    }

    // MARK: Canvas

    @ViewBuilder
    private var canvas: some View {
        if let src = model.source, let before = model.beforeImage {
            CanvasView(model: model, before: before, pixelSize: src.uprightSize,
                       loupeEnabled: loupeOn && !model.isAnalyzing, cursor: $cursor)
                .overlay(alignment: .top) {
                    if model.isAnalyzing {
                        Text("LOCATING SUBJECT · REFINING EDGES")
                            .font(Theme.mono(10, .bold)).tracking(1.5).foregroundStyle(.white)
                            .padding(.horizontal, 10).frame(height: 24).background(Theme.accent)
                            .padding(.top, 34)
                    }
                }
        } else {
            DropTarget(isTargeted: isDropTargeted) { model.chooseFile() }
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 0) {
            if let src = model.source {
                Text(info(src)).lineLimit(1)
            } else {
                Text("NO IMAGE")
            }
            Spacer()
            if let c = cursor {
                Text("X \(Int(c.x))  Y \(Int(c.y))").padding(.trailing, 16)
            }
            if let url = model.savedURL {
                HStack(spacing: 8) {
                    Rectangle().fill(Color(hex: 0x3DDC97)).frame(width: 6, height: 6)
                    Text("SAVED \(url.lastPathComponent)").lineLimit(1)
                    Button("SHOW IN FINDER") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
                .padding(.trailing, 16)
                .task(id: url) {
                    try? await Task.sleep(for: .seconds(10))
                    if model.savedURL == url { model.savedURL = nil }
                }
            }
            Button { loupeOn.toggle() } label: {
                Text("LOUPE \(loupeOn ? "ON" : "OFF")").foregroundStyle(loupeOn ? Theme.accent : Theme.sky)
            }
            .buttonStyle(.plain)
            .help("Pixel loupe")
        }
        .font(Theme.mono(10))
        .foregroundStyle(Theme.sky)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Theme.panel)
    }

    private func info(_ src: SourceImage) -> String {
        var parts = ["\(src.width) × \(src.height) PX"]
        if let dpi = src.dpi { parts.append("\(Int(dpi)) DPI") }
        if let p = src.profileName { parts.append(p.uppercased()) }
        let inExt = src.type.preferredFilenameExtension?.uppercased() ?? "?"
        let outExt = model.outputType?.preferredFilenameExtension?.uppercased() ?? "?"
        parts.append("\(inExt) → \(outExt)")
        parts.append("METADATA KEPT")
        return parts.joined(separator: "  ·  ")
    }
}

/// Indeterminate 2-pt cobalt line, only animating while busy.
struct ProgressLine: View {
    let active: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Theme.line
                if active {
                    Theme.accent.frame(width: g.size.width * 0.25)
                        .offset(x: phase * g.size.width * 1.25 - g.size.width * 0.25)
                        .onAppear {
                            phase = 0
                            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
                        }
                }
            }
        }
        .frame(height: active ? 2 : 1)
        .clipped()
    }
}

/// Empty state: a drafting-table drop target.
struct DropTarget: View {
    let isTargeted: Bool
    let browse: () -> Void

    var body: some View {
        ZStack {
            BlueprintGrid()
            VStack(spacing: 22) {
                ZStack {
                    Rectangle()
                        .strokeBorder(isTargeted ? Theme.accent : Theme.sky.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                        .background(isTargeted ? Theme.accent.opacity(0.12) : Theme.ink.opacity(0.6))
                    CropMarks(length: 18, gap: 8).stroke(Theme.accent, lineWidth: 1.5)
                    VStack(spacing: 10) {
                        Text(isTargeted ? "RELEASE" : "DROP IMAGE")
                            .font(.system(size: 30, weight: .black)).tracking(6)
                        Text("Remove or recolor the background, or stamp a watermark.\nUnchanged pixels stay bit-identical.")
                            .font(.system(size: 12)).foregroundStyle(Theme.sky)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(width: 440, height: 220)

                HStack(spacing: 14) {
                    Button("OPEN FILE  ⌘O", action: browse).buttonStyle(OutlineButtonStyle())
                    Text("JPEG · PNG · HEIC · TIFF").font(Theme.mono(10)).foregroundStyle(Theme.sky)
                }
            }
        }
        .background(Theme.ink)
    }
}
