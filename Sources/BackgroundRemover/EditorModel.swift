import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case background = "Background"
        case watermark = "Watermark"
        var id: String { rawValue }
    }

    enum BackgroundMode: String, CaseIterable, Identifiable {
        case keep = "Keep"
        case remove = "Remove"
        case color = "Color"
        var id: String { rawValue }
    }

    @Published var tool: Tool = .background {
        didSet { if tool == .watermark && !watermarkTouched { watermarkTouched = true; watermark.enabled = true } }
    }

    @Published private(set) var source: SourceImage?
    @Published private(set) var beforeImage: NSImage?
    @Published private(set) var afterImage: NSImage?
    @Published private(set) var watermarkPreview: NSImage?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isRendering = false
    @Published var errorMessage: String?
    @Published var savedURL: URL?

    @Published var mode: BackgroundMode = .remove { didSet { if mode != oldValue { formatChoice = nil; refreshResult() } } }
    @Published var color: Color = .white { didSet { if mode == .color { refreshResult() } } }
    @Published var crisp: Double = 2 { didSet { if crisp != oldValue { refreshResult(delay: 150) } } }
    @Published var trim: Double = 0 { didSet { if trim != oldValue { refreshResult(delay: 150) } } }
    @Published var watermark = WatermarkSettings() { didSet { if watermark != oldValue { refreshWatermark() } } }
    /// nil = automatic (original format, or PNG when transparency needs it).
    @Published var formatChoice: UTType?

    private var session: EditSession?
    private var renderTask: Task<Void, Never>?
    private var watermarkTask: Task<Void, Never>?
    private var loadToken = UUID()
    private var watermarkTouched = false

    var isBusy: Bool { isAnalyzing || isRendering }

    var needsAlpha: Bool {
        mode == .remove || (mode == .keep && session.map { !$0.raw.opaque } ?? false)
    }

    var background: Background {
        switch mode {
        case .keep: return .keep
        case .remove: return .transparent
        case .color: return .color((NSColor(color).usingColorSpace(.sRGB) ?? .white).cgColor)
        }
    }

    var autoType: UTType? { source.map { ImageWriter.outputType(for: $0, transparent: needsAlpha) } }
    var outputType: UTType? { formatChoice ?? autoType }
    var formatChoices: [UTType] { ImageWriter.choices(transparent: needsAlpha) }

    // MARK: Loading

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        renderTask?.cancel()
        let token = UUID()
        loadToken = token
        session = nil // release the previous image's buffers right away
        afterImage = nil
        savedURL = nil
        errorMessage = nil
        formatChoice = nil
        Task {
            do {
                let (s, before) = try await Task.detached(priority: .userInitiated) {
                    let src = try SourceImage.load(from: url)
                    let s = try EditSession(source: src)
                    return (s, Compositor.displayImage(src.cgImage, orientation: src.orientation))
                }.value
                guard token == loadToken else { return }
                session = s
                source = s.source
                beforeImage = NSImage(display: before)
                refreshResult()
                refreshWatermark()
            } catch {
                guard token == loadToken else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Rendering

    /// Re-renders the background result (without watermark — that's previewed as a cheap overlay).
    private func refreshResult(delay: Int = 0) {
        guard let session else { return }
        renderTask?.cancel()
        if mode == .keep {
            afterImage = beforeImage
            isRendering = false
            return
        }
        let background = self.background, crisp = self.crisp, trim = self.trim
        let needsMatte = !session.hasMatte
        if needsMatte { isAnalyzing = true } else { isRendering = true }
        renderTask = Task {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled else { return }
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> CGImage in
                    let cg = try session.render(background: background, crisp: crisp, trim: trim, watermark: nil)
                    return Compositor.displayImage(cg, orientation: session.source.orientation)
                }.value
                guard !Task.isCancelled else { return }
                afterImage = NSImage(display: result)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                if needsMatte { mode = .keep } // e.g. a document with no subject: fall back to Keep
            }
            isAnalyzing = false
            isRendering = false
        }
    }

    private func refreshWatermark() {
        guard let source else { return }
        watermarkTask?.cancel()
        let s = watermark, size = source.uprightSize
        watermarkTask = Task {
            let cg = await Task.detached(priority: .userInitiated) {
                WatermarkRenderer.preview(s, uprightSize: size)
            }.value
            guard !Task.isCancelled else { return }
            watermarkPreview = cg.map { NSImage(display: $0) }
        }
    }

    func align(_ a: WatermarkAlign) {
        guard let source else { return }
        let c = WatermarkRenderer.center(for: a, watermark, imageSize: source.uprightSize)
        watermark.layout = .single
        watermark.x = c.x
        watermark.y = c.y
    }

    /// Which preset (if any) the current position matches.
    var currentAlign: WatermarkAlign? {
        guard let source, watermark.layout == .single else { return nil }
        return WatermarkAlign.allCases.first { a in
            let c = WatermarkRenderer.center(for: a, watermark, imageSize: source.uprightSize)
            return abs(c.x - watermark.x) < 0.002 && abs(c.y - watermark.y) < 0.002
        }
    }

    // MARK: Export

    func save() {
        guard let session, let type = outputType else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.directoryURL = session.source.url.deletingLastPathComponent()
        let base = session.source.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base)-edited.\(type.preferredFilenameExtension ?? "png")"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let background = self.background, crisp = self.crisp, trim = self.trim
        let wm: WatermarkSettings? = watermark.isVisible ? watermark : nil
        isRendering = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let cg = try session.render(background: background, crisp: crisp, trim: trim, watermark: wm)
                    try ImageWriter.write(cg, to: dest, type: type, source: session.source)
                }.value
                savedURL = dest
            } catch {
                errorMessage = error.localizedDescription
            }
            isRendering = false
        }
    }
}

private extension NSImage {
    convenience init(display cg: CGImage) {
        self.init(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
