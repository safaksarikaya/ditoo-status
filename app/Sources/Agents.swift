import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One session of an AI agent: Claude Code (through its hooks) or any agent that reports with `--agent`.
struct AgentSession: Equatable {
  var agent: String, id: String, state: ClaudeState
  var key: String { agent + "/" + id }
}

/// Session states of every agent, in agents_state.json:
/// {"agents": {"claude": {"<session>": ["working", <unix time>]}, "codex": {...}}}
enum AgentStore {
  typealias Sessions = [String: (ClaudeState, Double)]

  /// Live sessions: Claude first, then other agents by name; sessions by id (stable dot order).
  static func read() -> [AgentSession] {
    guard let data = try? Data(contentsOf: Paths.agentsState) else { return [] }
    let all = parse(data)
    let names = all.keys.sorted { ($0 == "claude" ? "" : $0) < ($1 == "claude" ? "" : $1) }
    return names.flatMap { a in
      fresh(all[a] ?? [:]).sorted { $0.key < $1.key }.map { AgentSession(agent: a, id: $0.key, state: $0.value.0) }
    }
  }

  /// Agent names become folder names: lowercase letters, digits, - and _.
  static func validName(_ s: String) -> String? {
    let n = s.lowercased()
    let ok = !n.isEmpty && n.count <= 32 && n.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    return ok ? n : nil
  }

  /// Records a state ("working", "waiting", "done", or "end" to drop the session). Returns an error, if any.
  @discardableResult
  static func record(agent: String, session: String, state: String) -> String? {
    guard let agent = validName(agent) else { return "agent name: lowercase letters, digits, - and _ (max 32)" }
    guard state == "end" || ClaudeState(rawValue: state) != nil else { return "state: working | waiting | done | end" }
    let fd = open(Paths.agentsState.path, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0 else { return "can't open \(Paths.agentsState.path)" }
    flock(fd, LOCK_EX)  // concurrent hooks take turns
    defer { flock(fd, LOCK_UN); close(fd) }
    let h = FileHandle(fileDescriptor: fd)
    var all = parse(h.readDataToEndOfFile())
    var s = all[agent] ?? [:]
    let now = Date().timeIntervalSince1970
    if state == "end" {
      s[session] = nil
    } else if let cur = s[session], cur.0.rawValue == state, now - cur.1 < 600 {
      return nil  // unchanged: don't touch the file (some hooks fire often); refresh every 10 min
    } else if let st = ClaudeState(rawValue: state) {
      s[session] = (st, now)
    }
    all[agent] = s
    all = all.mapValues(fresh).filter { !$0.value.isEmpty }
    let json: [String: Any] = ["agents": all.mapValues { $0.mapValues { [$0.0.rawValue, $0.1] as [Any] } }]
    if let out = try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys) {
      ftruncate(fd, 0); lseek(fd, 0, SEEK_SET)
      h.write(out)
    }
    return nil
  }

  /// `DitooStatus --agent <name> <state> [session]`, for other agents' hooks and scripts.
  static func runCLI(_ args: [String]) -> Never {
    guard args.count == 2 || args.count == 3 else {
      FileHandle.standardError.write(Data("usage: ditoo-agent <agent> <working|waiting|done|end> [session]\n".utf8))
      exit(2)
    }
    if let err = record(agent: args[0], session: args.count == 3 ? args[2] : "default", state: args[1].lowercased()) {
      FileHandle.standardError.write(Data((err + "\n").utf8))
      exit(2)
    }
    exit(0)
  }

  private static func parse(_ data: Data) -> [String: Sessions] {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let agents = obj["agents"] as? [String: [String: [Any]]] else { return [:] }
    return agents.mapValues { s in
      var out: Sessions = [:]
      for (k, v) in s {
        if v.count == 2, let st = (v[0] as? String).flatMap(ClaudeState.init), let t = v[1] as? Double { out[k] = (st, t) }
      }
      return out
    }
  }

  private static func fresh(_ s: Sessions) -> Sessions {
    let now = Date().timeIntervalSince1970
    return s.filter { now - $0.value.1 < (ClaudeState.staleAfter[$0.value.0] ?? 3600) }
  }
}

/// Optional agents/<name>/agent.json.
struct AgentInfo: Codable {
  var name: String?
  var dots: Bool?  // draw the session dots in the right column
  var keys: [String: Int]?  // key-light effect per state: "working", "waiting"
}

/// Each agent's screens come from its own folder, agents/<name>/: working.gif, waiting.gif, done.gif
/// (or default.gif for any state without its own file; PNG works too). We ship only Claude's,
/// exported from the built-in mascot so anyone can restyle it.
final class AgentVisuals {
  static let exts = ["gif", "png", "webp", "jpg", "jpeg", "heic", "bmp"]
  private var anims: [String: (Date, Animation?)] = [:]
  private var infos: [String: (Date, AgentInfo)] = [:]

  func folder(_ agent: String) -> URL { Paths.agents.appendingPathComponent(agent, isDirectory: true) }

  func info(_ agent: String) -> AgentInfo {
    let u = folder(agent).appendingPathComponent("agent.json")
    guard let m = mtime(u) else { return AgentInfo() }
    if let c = infos[u.path], c.0 == m { return c.1 }
    var i = AgentInfo()
    do { i = try JSONDecoder().decode(AgentInfo.self, from: Data(contentsOf: u)) } catch {
      Log.write("agents: \(agent)/agent.json unreadable: \(error)")
    }
    infos[u.path] = (m, i)
    return i
  }

  func name(_ agent: String) -> String { info(agent).name ?? (agent == "claude" ? "Claude" : agent.capitalized) }

  /// The agent has something to show (Claude always has the built-in mascot).
  func canShow(_ agent: String) -> Bool {
    agent == "claude" || ["working", "waiting", "done", "default"].contains { file(agent, $0) != nil }
  }

  /// The screen for an agent whose sessions are in `states`; nil when it has no visuals.
  func animation(_ agent: String, _ states: [ClaudeState]) -> Animation? {
    guard let mood = ClaudeState.mood(of: states) else { return nil }
    if let f = file(agent, mood.rawValue) ?? file(agent, "default"), let a = load(f) {
      return info(agent).dots ?? (agent == "claude") ? Screens.withDots(a, states) : a
    }
    return agent == "claude" ? Screens.claude(states) : nil
  }

  private func file(_ agent: String, _ base: String) -> URL? {
    let d = folder(agent)
    return AgentVisuals.exts.lazy.map { d.appendingPathComponent("\(base).\($0)") }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  private func load(_ u: URL) -> Animation? {
    guard let m = mtime(u) else { return nil }
    if let c = anims[u.path], c.0 == m { return c.1 }
    let a = DrawModel.loadFrames(u).map { Animation(frames: $0.map { ($0.px, $0.ms) }) }
    if a == nil { Log.write("agents: can't read \(u.path)") }
    anims[u.path] = (m, a)
    return a
  }

  private func mtime(_ u: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
  }

  // MARK: setup files

  /// Writes the README and the `ditoo-agent` command; exports Claude's visuals the first time.
  static func setUp() {
    let fm = FileManager.default
    try? fm.createDirectory(at: Paths.agents, withIntermediateDirectories: true)
    try? readme.write(to: Paths.agents.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    if let exe = Bundle.main.executablePath {
      let script = """
        #!/bin/sh
        # Report an AI agent's state to Ditoo Status: ditoo-agent <agent> <working|waiting|done|end> [session]
        exec "\(exe)" --agent "$@"

        """
      try? script.write(to: Paths.agentCommand, atomically: true, encoding: .utf8)
      try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.agentCommand.path)
    }
    if !fm.fileExists(atPath: Paths.agents.appendingPathComponent("claude").path) { exportClaude() }
    // Sessions from the older claude_state.json carry over once.
    let old = Paths.support.appendingPathComponent("claude_state.json")
    if let d = try? Data(contentsOf: old),
       let s = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["sessions"] as? [String: [Any]] {
      for (id, v) in s { if let st = v.first as? String { AgentStore.record(agent: "claude", session: id, state: st) } }
    }
    try? fm.removeItem(at: old)
  }

  /// Claude's built-in mascot as editable GIFs (160x160, 10x pixels), without the session dots.
  static func exportClaude() {
    let d = Paths.agents.appendingPathComponent("claude", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    for m in [ClaudeState.working, .waiting, .done] {
      writeGIF(Screens.claude([], mood: m, dots: false), to: d.appendingPathComponent("\(m.rawValue).gif"))
    }
    let info = #"{"name": "Claude", "dots": true}"#
    try? info.write(to: d.appendingPathComponent("agent.json"), atomically: true, encoding: .utf8)
    Log.write("agents: exported Claude's visuals")
  }

  @discardableResult
  static func writeGIF(_ a: Animation, to url: URL, scale: Int = 10) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, a.frames.count, nil)
    else { return false }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let n = 16 * scale
    for f in a.frames {
      var bytes = [UInt8](repeating: 255, count: n * n * 4)
      for y in 0..<n {
        for x in 0..<n {
          let p = f.px[(y / scale) * 16 + x / scale], o = (y * n + x) * 4
          bytes[o] = p.r; bytes[o + 1] = p.g; bytes[o + 2] = p.b
        }
      }
      guard let provider = CGDataProvider(data: Data(bytes) as CFData),
            let img = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
      else { return false }
      let delay = Double(max(f.ms, 20)) / 1000
      CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    return CGImageDestinationFinalize(dest)
  }

  static let readme = """
    Ditoo Status: agents
    ====================

    Any AI agent (or script) can show its state on the Ditoo.

    1. Report the state, e.g. from the agent's hooks:

         "\(Paths.agentCommand.path)" <agent> <state> [session]

       agent:   lowercase name, also the folder name below (e.g. codex)
       state:   working | waiting (needs you) | done | end (session closed)
       session: any id, so several sessions of one agent get their own dot (default: "default")

       A state goes stale without updates: working after 15 min, waiting after 2 h, done after 12 h.
       Report working again from time to time during long tasks.

    2. Give it visuals: a folder here named after the agent, with

         working.gif   waiting.gif   done.gif     (or .png)

       16x16 pixels, or a multiple such as 160x160 (stays sharp). default.gif covers any state
       without its own file. An agent without visuals still drives the key lights and the menu,
       but doesn't appear on the screen.

    3. Optional agent.json in that folder:

         {"name": "Codex", "dots": false, "keys": {"working": 8, "waiting": 2}}

       name: shown in the menu · dots: draw the session dots in the right column ·
       keys: key-light effect numbers for this agent (see Settings > key lights).

    The "claude" folder holds the Claude Code mascot (Clawd, Anthropic's character), exported
    from the app. Edit the GIFs to restyle it; delete one to fall back to the built-in mascot,
    or use Settings > Agents > Restore Claude's visuals.

    """
}
