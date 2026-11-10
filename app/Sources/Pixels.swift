import Foundation

/// 24-bit color. Stored in config as [r, g, b].
struct RGB: Hashable, Codable {
  var r: UInt8, g: UInt8, b: UInt8
  init(_ r: Int, _ g: Int, _ b: Int) {
    self.r = UInt8(clamping: r); self.g = UInt8(clamping: g); self.b = UInt8(clamping: b)
  }
  static let black = RGB(0, 0, 0)
  func dimmed(_ by: Int) -> RGB { RGB(Int(r) / by, Int(g) / by, Int(b) / by) }

  init(from decoder: Decoder) throws {
    var c = try decoder.unkeyedContainer()
    self.init(try c.decode(Int.self), try c.decode(Int.self), try c.decode(Int.self))
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.unkeyedContainer()
    try c.encode(Int(r)); try c.encode(Int(g)); try c.encode(Int(b))
  }
}

/// 16x16 drawing surface, row-major from the top-left.
struct PixelCanvas {
  static let size = 16
  var px: [RGB]

  init(_ bg: RGB = .black) { px = Array(repeating: bg, count: PixelCanvas.size * PixelCanvas.size) }

  mutating func set(_ x: Int, _ y: Int, _ c: RGB) {
    guard (0..<PixelCanvas.size).contains(x), (0..<PixelCanvas.size).contains(y) else { return }
    px[y * PixelCanvas.size + x] = c
  }

  mutating func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: RGB) {
    guard x0 <= x1, y0 <= y1 else { return }
    for y in y0...y1 { for x in x0...x1 { set(x, y, c) } }
  }

  /// rows: strings where each character maps to a color in `colors`; other characters are transparent.
  mutating func sprite(_ rows: [String], _ x0: Int, _ y0: Int, _ colors: [Character: RGB]) {
    for (dy, row) in rows.enumerated() {
      for (dx, ch) in row.enumerated() {
        if let c = colors[ch] { set(x0 + dx, y0 + dy, c) }
      }
    }
  }

  @discardableResult
  mutating func text(_ s: String, _ x0: Int, _ y0: Int, _ c: RGB) -> Int {
    var x = x0
    for ch in s {
      guard let g = PixelCanvas.font[ch] else { continue }
      sprite(g, x, y0, ["#": c])
      x += g[0].count + 1
    }
    return x
  }

  static func textWidth(_ s: String) -> Int {
    s.compactMap { font[$0]?[0].count }.reduce(0) { $0 + $1 + 1 } - 1
  }

  /// 3x5 digits and percent sign.
  static let font: [Character: [String]] = [
    "0": ["###", "#.#", "#.#", "#.#", "###"],
    "1": [".#.", "##.", ".#.", ".#.", "###"],
    "2": ["###", "..#", "###", "#..", "###"],
    "3": ["###", "..#", "###", "..#", "###"],
    "4": ["#.#", "#.#", "###", "..#", "..#"],
    "5": ["###", "#..", "###", "..#", "###"],
    "6": ["###", "#..", "###", "#.#", "###"],
    "7": ["###", "..#", ".#.", ".#.", ".#."],
    "8": ["###", "#.#", "###", "#.#", "###"],
    "9": ["###", "#.#", "###", "..#", "###"],
    "%": ["#.#", "..#", ".#.", "#..", "#.#"],
  ]
}

/// An animation: frames with per-frame duration in milliseconds.
struct Animation {
  var frames: [(px: [RGB], ms: Int)]
  static func still(_ c: PixelCanvas) -> Animation { Animation(frames: [(c.px, 0)]) }
}

// MARK: - Screens

enum Screens {
  // Claude Code mascot ("Clawd"), 12x8.
  static let orange = RGB(217, 119, 87)
  static let dotColors: [ClaudeState: RGB] = [
    .waiting: RGB(255, 30, 30), .working: RGB(255, 190, 0), .done: RGB(40, 220, 80),
  ]

  enum Eyes { case open, closed, happy }
  enum Legs { case all, a, b, tuck }

  static func clawd(_ c: inout PixelCanvas, _ x: Int, _ y: Int, eyes: Eyes, legs: Legs, armsUp: Bool) {
    c.rect(x + 1, y, x + 10, y + 5, orange)
    let armY = armsUp ? y + 1 : y + 3
    for ax in [x, x + 11] {
      c.rect(ax, armY, ax, armY + 1, orange)
      if armsUp { c.set(ax, y + 3, orange) }
    }
    for ex in [x + 3, x + 8] {
      switch eyes {
      case .open: c.rect(ex, y + 1, ex, y + 2, .black)
      case .closed: c.set(ex, y + 2, .black)
      case .happy:
        c.set(ex, y + 1, .black); c.set(ex - 1, y + 2, .black); c.set(ex + 1, y + 2, .black)
      }
    }
    for (i, lx) in [x + 1, x + 3, x + 8, x + 10].enumerated() {
      let short = legs == .tuck || (legs == .a && i % 2 == 1) || (legs == .b && i % 2 == 0)
      c.rect(lx, y + 6, lx, short ? y + 6 : y + 7, orange)
    }
  }

  /// Mascot animation for the overall mood plus one dot per session (max 4).
  /// The mascot for these sessions (mood: waiting > working > done), with a dot per session.
  static func claude(_ states: [ClaudeState], mood forced: ClaudeState? = nil, dots: Bool = true) -> Animation {
    let mood = forced ?? ClaudeState.mood(of: states)
    typealias Step = (dy: Int, eyes: Eyes, legs: Legs, up: Bool, dim: Bool, ms: Int)
    let plan: [Step]
    switch mood {
    case .working: plan = [(0, .open, .a, false, false, 250), (0, .open, .b, false, true, 250)]
    case .waiting:
      plan = [(0, .open, .all, true, false, 220), (-2, .open, .tuck, true, true, 220),
              (0, .open, .all, false, false, 220), (-2, .open, .tuck, true, true, 220)]
    case .done:
      plan = [(0, .happy, .all, false, false, 300), (-1, .happy, .tuck, true, false, 300),
              (0, .happy, .all, false, false, 1200)]
    case nil: plan = [(0, .open, .all, false, false, 2500), (0, .closed, .all, false, false, 150)]
    }
    var out = Animation(frames: [])
    for s in plan {
      var c = PixelCanvas()
      clawd(&c, 0, 5 + s.dy, eyes: s.eyes, legs: s.legs, armsUp: s.up)
      out.frames.append((c.px, s.ms))
    }
    return dots ? withDots(out, states) : out
  }

  /// Up to 4 session dots in the right column; they dim on every other frame unless done.
  static func withDots(_ a: Animation, _ states: [ClaudeState]) -> Animation {
    var out = a
    for f in out.frames.indices {
      var c = PixelCanvas()
      c.px = out.frames[f].px
      for (i, st) in states.prefix(4).enumerated() {
        var col = dotColors[st] ?? RGB(80, 80, 80)
        if f % 2 == 1 && st != .done { col = col.dimmed(5) }
        c.rect(13, 1 + 4 * i, 14, 2 + 4 * i, col)
      }
      out.frames[f].px = c.px
    }
    return out
  }

  // Battery icons: a mouse seen from above, a keyboard with an orange Esc key.
  static let mouse = ["..LDL..", ".LLDLL.", "LLLOLLS", "LLLOLLS", "LLLDLLS", "LLLLLLS", "LLLLLLS", ".LLLLS.", "..SSS.."]
  static let mouseColors: [Character: RGB] = [
    "L": RGB(225, 225, 235), "S": RGB(140, 140, 160), "D": RGB(55, 55, 70), "O": RGB(217, 119, 87),
  ]
  static let bolt = ["..#", ".#.", "###", ".#.", "#.."]
  static let keyboard = [
    ".ooooooooooooo.", "offfffffffffffo", "ofOkfkkfkkfkkfo",
    "offfffffffffffo", "ofkkfkkfkkfkkfo", "offfffffffffffo",
    "ofkkfkkkkkfkkfo", "ossssssssssssso", ".ooooooooooooo.",
  ]
  static let keyboardColors: [Character: RGB] = [
    "o": RGB(170, 170, 190), "f": RGB(45, 45, 60), "s": RGB(90, 90, 110), "k": RGB(210, 210, 225),
    "O": RGB(217, 119, 87),
  ]

  static func batteryColor(_ pct: Int) -> RGB {
    pct <= 10 ? RGB(255, 30, 30) : pct <= 20 ? RGB(255, 140, 0) : RGB(40, 220, 80)
  }

  static func battery(isKeyboard: Bool, pct: Int) -> Animation {
    var c = PixelCanvas()
    let col = batteryColor(pct)
    icon(&c, isKeyboard: isKeyboard)
    c.rect(1, 9, 14, 9, RGB(40, 40, 40))
    c.rect(1, 9, max(1, Int((1 + 13 * Double(pct) / 100).rounded())), 9, col)
    let t = "\(pct)%"
    c.text(t, (16 - PixelCanvas.textWidth(t)) / 2, 11, col)
    return .still(c)
  }

  static func icon(_ c: inout PixelCanvas, isKeyboard: Bool) {
    if isKeyboard { c.sprite(keyboard, 0, 0, keyboardColors) } else { c.sprite(mouse, 4, 0, mouseColors) }
  }

  /// Charging: the bar fills up in a loop, a bolt sits next to the percentage (no bolt at 100%).
  static func charging(isKeyboard: Bool, pct: Int) -> Animation {
    let green = RGB(40, 220, 80), yellow = RGB(255, 210, 0)
    let fill = max(1, Int((1 + 13 * Double(pct) / 100).rounded()))
    let t = "\(pct)%"
    let full = pct >= 100
    let w = PixelCanvas.textWidth(t) + (full ? 0 : 4)
    var out = Animation(frames: [])
    for k in 0..<(full ? 1 : 4) {
      var c = PixelCanvas()
      icon(&c, isKeyboard: isKeyboard)
      c.rect(1, 9, 14, 9, RGB(40, 40, 40))
      c.rect(1, 9, fill + (14 - fill) * k / 3, 9, green.dimmed(3))
      c.rect(1, 9, fill, 9, green)
      var x = (16 - w) / 2
      if !full { c.sprite(bolt, x, 11, ["#": yellow]); x += 4 }
      c.text(t, x, 11, green)
      out.frames.append((c.px, full ? 0 : 350))
    }
    return out
  }
}
