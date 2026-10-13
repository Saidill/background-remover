import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BackgroundRemoverApp: App {
    init() {
        // Needed when launched as a bare executable (`swift run`) rather than a .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Cutout") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}

/// Headless mode for scripting/testing:
///   BackgroundRemover --process <input> <output> [--keep | --color RRGGBB] [--crisp 1-4] [--trim 0-0.4]
///       [--watermark TEXT] [--wm-size %] [--wm-opacity 0-1] [--wm-rotation deg] [--wm-tile] [--wm-pos x,y]
func runCLI(_ args: [String]) -> Int32 {
    guard args.count >= 3 else {
        print("usage: BackgroundRemover --process <input> <output> [--keep | --color RRGGBB] [--crisp 1-4] [--trim 0-0.4] "
            + "[--watermark TEXT] [--wm-size %] [--wm-opacity 0-1] [--wm-rotation deg] [--wm-tile] [--wm-pos x,y]")
        return 2
    }
    let input = URL(fileURLWithPath: args[1])
    var output = URL(fileURLWithPath: args[2])
    var background = Background.transparent
    var crisp = 2.0, trim = 0.0
    var wm = WatermarkSettings()
    var i = 3
    while i < args.count {
        let value = i + 1 < args.count ? args[i + 1] : ""
        switch args[i] {
        case "--keep": background = .keep; i -= 1
        case "--wm-tile": wm.layout = .tiled; i -= 1
        case "--color":
            if let v = UInt32(value.trimmingCharacters(in: ["#"]), radix: 16) {
                background = .color(CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                                            green: CGFloat((v >> 8) & 0xFF) / 255,
                                            blue: CGFloat(v & 0xFF) / 255, alpha: 1))
            }
        case "--crisp": crisp = Double(value) ?? crisp
        case "--trim": trim = Double(value) ?? trim
        case "--watermark": wm.enabled = true; wm.text = value
        case "--wm-size": wm.sizePercent = Double(value) ?? wm.sizePercent
        case "--wm-opacity": wm.opacity = Double(value) ?? wm.opacity
        case "--wm-rotation": wm.rotation = Double(value) ?? wm.rotation
        case "--wm-pos":
            let xy = value.split(separator: ",").compactMap { Double($0) }
            if xy.count == 2 { wm.x = xy[0]; wm.y = xy[1] }
        default: break
        }
        i += 2
    }

    do {
        let src = try SourceImage.load(from: input)
        let session = try EditSession(source: src)
        var transparent = false
        switch background {
        case .transparent: transparent = true
        case .keep: transparent = !session.raw.opaque
        case .color: break
        }
        // Honor the output extension when it's a valid choice; otherwise pick automatically.
        let requested = UTType(filenameExtension: output.pathExtension)
        let type = requested.flatMap { r in ImageWriter.choices(transparent: transparent).first { $0 == r } }
            ?? ImageWriter.outputType(for: src, transparent: transparent)
        if let ext = type.preferredFilenameExtension, output.pathExtension.lowercased() != ext,
           UTType(filenameExtension: output.pathExtension) != type {
            output = output.deletingPathExtension().appendingPathExtension(ext)
        }
        let cg = try session.render(background: background, crisp: crisp, trim: trim,
                                    watermark: wm.isVisible ? wm : nil)
        try ImageWriter.write(cg, to: output, type: type, source: src)
        print("saved \(output.path) (\(cg.width)×\(cg.height), \(type.identifier))")
        return 0
    } catch {
        print("error: \(error.localizedDescription)")
        return 1
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--process" {
    exit(runCLI(arguments))
} else {
    BackgroundRemoverApp.main()
}
