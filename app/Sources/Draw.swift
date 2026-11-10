import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One frame of the user's drawing.
struct DrawingFrame: Codable, Equatable {
  var px: [RGB]
  var ms: Int
  static func blank(ms: Int = 200) -> DrawingFrame { DrawingFrame(px: Array(repeating: .black, count: 256), ms: ms) }
}

/// The user's 16x16 drawing or animation, saved next to the settings.
final class DrawModel: ObservableObject {
  enum Tool: String, CaseIterable { case pencil, eraser, fill, picker }

  @Published var frames: [DrawingFrame]
  @Published var current = 0
  @Published var tool = Tool.pencil
  @Published var color = RGB(217, 119, 87)
  @Published var importError: String?
  /// Called after each finished edit (stroke, import, frame change).
  var onChange: () -> Void = {}

  private var undoStack: [[DrawingFrame]] = []
  private var stroking = false
  static let file = Paths.support.appendingPathComponent("drawing.json")
  static let maxFrames = 60

  init() {
    if let d = try? Data(contentsOf: DrawModel.file), let f = try? JSONDecoder().decode([DrawingFrame].self, from: d),
       !f.isEmpty {
      frames = f
    } else {
      frames = [.blank()]
    }
  }

  var isEmpty: Bool { frames.allSatisfy { $0.px.allSatisfy { $0 == .black } } }

  var animation: Animation? {
    guard !isEmpty else { return nil }
    var a = Animation(frames: frames.map { ($0.px, frames.count > 1 ? $0.ms : 0) })
    // The upload holds at most 255 chunks of 200 bytes; drop trailing frames past that.
    while a.frames.count > 1, Proto.animation(a).count > 250 { a.frames.removeLast() }
    return a
  }

  private func commit() {
    try? JSONEncoder().encode(frames).write(to: DrawModel.file, options: .atomic)
    onChange()
  }

  private func pushUndo() {
    undoStack.append(frames)
    if undoStack.count > 50 { undoStack.removeFirst() }
  }

  var canUndo: Bool { !undoStack.isEmpty }

  func undo() {
    guard let last = undoStack.popLast() else { return }
    frames = last
    current = min(current, frames.count - 1)
    commit()
  }

  // MARK: editing

  func stroke(_ x: Int, _ y: Int) {
    guard (0..<16).contains(x), (0..<16).contains(y) else { return }
    let i = y * 16 + x
    if tool == .picker { color = frames[current].px[i]; tool = .pencil; return }
    if !stroking { pushUndo(); stroking = true }
    switch tool {
    case .pencil: frames[current].px[i] = color
    case .eraser: frames[current].px[i] = .black
    case .fill: floodFill(from: i)
    case .picker: break
    }
  }

  func endStroke() {
    guard stroking else { return }
    stroking = false
    commit()
  }

  private func floodFill(from start: Int) {
    var px = frames[current].px
    let target = px[start]
    guard target != color else { return }
    var stack = [start]
    while let i = stack.popLast() {
      guard px[i] == target else { continue }
      px[i] = color
      let x = i % 16, y = i / 16
      if x > 0 { stack.append(i - 1) }
      if x < 15 { stack.append(i + 1) }
      if y > 0 { stack.append(i - 16) }
      if y < 15 { stack.append(i + 16) }
    }
    frames[current].px = px
  }

  func clearFrame() { pushUndo(); frames[current] = .blank(ms: frames[current].ms); commit() }

  func addFrame() {
    guard frames.count < DrawModel.maxFrames else { return }
    pushUndo()
    frames.insert(frames[current], at: current + 1)  // copy of the current frame: easy to animate
    current += 1
    commit()
  }

  func deleteFrame() {
    guard frames.count > 1 else { return }
    pushUndo()
    frames.remove(at: current)
    current = min(current, frames.count - 1)
    commit()
  }

  func setDuration(_ ms: Int) { frames[current].ms = ms; commit() }
  func setAllDurations(_ ms: Int) { for i in frames.indices { frames[i].ms = ms }; commit() }

  // MARK: import

  func importImage(_ url: URL) {
    guard let f = DrawModel.loadFrames(url), !f.isEmpty else {
      importError = "Couldn't read that image."
      return
    }
    pushUndo()
    frames = f
    current = 0
    importError = f.count == 1 ? nil : "Imported \(f.count) frames."
    commit()
  }

  /// Any image macOS can read; GIF frames keep their timing. Scaled to fit 16x16 on black.
  static func loadFrames(_ url: URL) -> [DrawingFrame]? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let count = CGImageSourceGetCount(src)
    var out: [DrawingFrame] = []
    // Long GIFs: sample frames evenly and stretch their timing.
    let step = max(1, Int(ceil(Double(count) / Double(maxFrames))))
    for i in stride(from: 0, to: count, by: step) {
      guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
      var ms = 0
      for j in i..<min(i + step, count) { ms += delay(src, j) }
      out.append(DrawingFrame(px: limitColors(downscale(img)), ms: count > 1 ? max(20, min(ms, 60000)) : 200))
    }
    // Keep the upload under the protocol limit (255 chunks of 200 bytes).
    while out.count > 1, Proto.animation(Animation(frames: out.map { ($0.px, $0.ms) })).count > 250 {
      out = stride(from: 0, to: out.count, by: 2).map { i in
        var f = out[i]
        if i + 1 < out.count { f.ms += out[i + 1].ms }
        return f
      }
    }
    return out
  }

  private static func delay(_ src: CGImageSource, _ i: Int) -> Int {
    guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any] else { return 100 }
    for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary] {
      if let d = p[key] as? [CFString: Any] {
        let t = (d[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (d[kCGImagePropertyGIFDelayTime] as? Double)
          ?? (d[kCGImagePropertyAPNGUnclampedDelayTime] as? Double) ?? (d[kCGImagePropertyAPNGDelayTime] as? Double)
          ?? (d[kCGImagePropertyWebPUnclampedDelayTime] as? Double) ?? (d[kCGImagePropertyWebPDelayTime] as? Double)
        if let t, t > 0 { return Int(t * 1000) }
      }
    }
    return 100
  }

  private static func downscale(_ img: CGImage) -> [RGB] {
    var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    bytes.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(data: buf.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
      ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
      // Pixel art (a multiple of 16) stays sharp; photos get smoothed.
      let pixelArt = img.width % 16 == 0 && img.height % 16 == 0
      ctx.interpolationQuality = pixelArt ? .none : .high
      let s = 16 / Double(max(img.width, img.height))
      let w = Double(img.width) * s, h = Double(img.height) * s
      ctx.draw(img, in: CGRect(x: (16 - w) / 2, y: (16 - h) / 2, width: w, height: h))
    }
    var out: [RGB] = []
    for i in 0..<256 {
      let o = i * 4
      out.append(RGB(Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2])))
    }
    return out
  }

  /// The frame format holds at most 255 colors; round channels until it fits.
  private static func limitColors(_ px: [RGB]) -> [RGB] {
    var out = px, step = 4
    while Set(out).count > 255 {
      let q = { (v: UInt8) -> Int in Int(v) / step * step }
      out = px.map { RGB(q($0.r), q($0.g), q($0.b)) }
      step *= 2
    }
    return out
  }
}

// MARK: - Editor window

struct DrawView: View {
  @EnvironmentObject var model: AppModel
  @EnvironmentObject var draw: DrawModel
  @EnvironmentObject var screen: ScreenManager

  static let palette: [RGB] = [
    RGB(255, 255, 255), RGB(140, 140, 150), RGB(60, 60, 70), RGB(217, 119, 87),
    RGB(255, 30, 30), RGB(255, 140, 0), RGB(255, 210, 0), RGB(40, 220, 80),
    RGB(0, 200, 200), RGB(40, 110, 255), RGB(150, 70, 255), RGB(255, 90, 180),
    RGB(120, 70, 30), RGB(255, 200, 150), RGB(0, 90, 40), RGB(20, 30, 90),
  ]

  var body: some View {
    HStack(alignment: .top, spacing: 18) {
      VStack(spacing: 8) {
        PixelGrid().frame(width: 384, height: 384)
        frameBar
      }
      VStack(alignment: .leading, spacing: 14) {
        Picker("", selection: $draw.tool) {
          Image(systemName: "pencil").tag(DrawModel.Tool.pencil).help("Pencil")
          Image(systemName: "eraser").tag(DrawModel.Tool.eraser).help("Eraser")
          Image(systemName: "drop.fill").tag(DrawModel.Tool.fill).help("Fill")
          Image(systemName: "eyedropper").tag(DrawModel.Tool.picker).help("Pick a color")
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 200)

        HStack {
          ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
          RoundedRectangle(cornerRadius: 3).fill(color(draw.color)).frame(width: 22, height: 22)
        }
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 4), count: 8), spacing: 4) {
          ForEach(Self.palette, id: \.self) { c in
            RoundedRectangle(cornerRadius: 3).fill(color(c)).frame(width: 22, height: 22)
              .overlay(RoundedRectangle(cornerRadius: 3).stroke(c == draw.color ? Color.accentColor : .clear, lineWidth: 2))
              .onTapGesture { draw.color = c; if draw.tool == .eraser || draw.tool == .picker { draw.tool = .pencil } }
          }
        }
        .frame(width: 200)

        HStack {
          Button("Undo") { draw.undo() }.disabled(!draw.canUndo).keyboardShortcut("z")
          Button("Clear") { draw.clearFrame() }
        }
        Button("Import image or GIF…") { importImage() }
        if let e = draw.importError { Text(e).font(.caption).foregroundStyle(.secondary) }

        Divider().frame(width: 200)
        Text("Preview").font(.caption).foregroundStyle(.secondary)
        PixelPreview(anim: draw.animation, placeholder: "Empty").frame(width: 96, height: 96)
        Button("Show on Ditoo") {
          if let a = draw.animation { screen.show(a, secs: 15, label: "Drawing") }
        }
        .disabled(draw.isEmpty)
        Toggle("Use as home screen", isOn: Binding(
          get: { model.config.home == .drawing },
          set: { model.config.home = $0 ? .drawing : .design }))
          .disabled(draw.isEmpty && model.config.home != .drawing)
        Spacer()
      }
      .frame(width: 210)
    }
    .padding(18)
    .fixedSize()
  }

  private var frameBar: some View {
    HStack(spacing: 8) {
      Button { draw.current = max(0, draw.current - 1) } label: { Image(systemName: "chevron.left") }
        .disabled(draw.current == 0)
      Text("Frame \(draw.current + 1) / \(draw.frames.count)").font(.caption.monospacedDigit()).frame(width: 90)
      Button { draw.current = min(draw.frames.count - 1, draw.current + 1) } label: { Image(systemName: "chevron.right") }
        .disabled(draw.current >= draw.frames.count - 1)
      Button { draw.addFrame() } label: { Image(systemName: "plus.square.on.square") }
        .help("Duplicate this frame").disabled(draw.frames.count >= DrawModel.maxFrames)
      Button { draw.deleteFrame() } label: { Image(systemName: "trash") }
        .help("Delete this frame").disabled(draw.frames.count < 2)
      if draw.frames.count > 1 {
        Stepper("\(draw.frames[draw.current].ms) ms",
                value: Binding(get: { draw.frames[draw.current].ms }, set: { draw.setDuration($0) }),
                in: 20...5000, step: 20)
          .font(.caption)
      }
    }
  }

  private var colorBinding: Binding<Color> {
    Binding(get: { color(draw.color) }, set: { c in
      let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
      draw.color = RGB(Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
      if draw.tool == .eraser || draw.tool == .picker { draw.tool = .pencil }
    })
  }

  private func importImage() {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.image]
    p.allowsMultipleSelection = false
    NSApp.activate(ignoringOtherApps: true)
    if p.runModal() == .OK, let url = p.url { draw.importImage(url) }
  }
}

/// The 16x16 editing surface: click or drag to paint.
struct PixelGrid: View {
  @EnvironmentObject var draw: DrawModel

  var body: some View {
    GeometryReader { geo in
      let cell = geo.size.width / 16
      let px = draw.frames[draw.current].px
      let prev = draw.current > 0 ? draw.frames[draw.current - 1].px : nil
      Canvas { g, size in
        g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.05)))
        for i in 0..<256 {
          let r = CGRect(x: CGFloat(i % 16) * cell + 1, y: CGFloat(i / 16) * cell + 1, width: cell - 2, height: cell - 2)
          if px[i] != .black {
            g.fill(Path(r), with: .color(color(px[i])))
          } else if let prev, prev[i] != .black {  // onion skin: the previous frame, faint
            g.fill(Path(r), with: .color(color(prev[i]).opacity(0.18)))
          } else {
            g.fill(Path(r), with: .color(Color(white: 0.12)))
          }
        }
      }
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { v in draw.stroke(Int(v.location.x / cell), Int(v.location.y / cell)) }
        .onEnded { _ in draw.endStroke() })
    }
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}
