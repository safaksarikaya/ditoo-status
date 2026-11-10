import Foundation

enum ClaudeState: String, Codable, CaseIterable {
  case waiting, working, done

  static let priority: [ClaudeState] = [.waiting, .working, .done]
  static let staleAfter: [ClaudeState: TimeInterval] = [.working: 900, .waiting: 7200, .done: 43200]

  /// Overall mood: waiting > working > done; nil = idle.
  static func mood(of states: [ClaudeState]) -> ClaudeState? { priority.first { states.contains($0) } }
}

enum Paths {
  static let support: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("DitooStatus", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
  }()
  static let config = support.appendingPathComponent("config.json")
  static let agentsState = support.appendingPathComponent("agents_state.json")
  static let agents = support.appendingPathComponent("agents", isDirectory: true)
  static let agentCommand = support.appendingPathComponent("ditoo-agent")
  static let log = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/DitooStatus.log")
  static let claudeSettings = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/settings.json")
}

enum Log {
  static func write(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(s)\n"
    print(line, terminator: "")
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: Paths.log) {
      h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
      try? data.write(to: Paths.log)
    }
  }
}

/// Claude Code's hook (`DitooStatus --hook`): records each session's state as agent "claude".
enum ClaudeSessions {
  /// Maps a hook event to the session's new state. nil = no change, "end" = drop the session.
  static func newState(for ev: [String: Any]) -> String? {
    switch ev["hook_event_name"] as? String {
    case "UserPromptSubmit", "PostToolUse": return "working"
    case "PermissionRequest": return "waiting"
    case "PreToolUse": return ev["tool_name"] as? String == "AskUserQuestion" ? "waiting" : nil
    case "Notification": return ev["notification_type"] as? String == "idle_prompt" ? nil : "waiting"
    case "Stop": return "done"
    case "SessionEnd": return "end"
    default: return nil
    }
  }

  /// Hook entry point: reads the hook JSON from stdin, records the state, never draws.
  static func runHook() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let ev = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let new = newState(for: ev) else { exit(0) }
    AgentStore.record(agent: "claude", session: ev["session_id"] as? String ?? "?", state: new)
    exit(0)
  }
}

/// Adds/removes this app's hook entries in ~/.claude/settings.json (with a backup).
enum ClaudeHooks {
  static let events: [(event: String, matcher: String?)] = [
    ("UserPromptSubmit", nil), ("PostToolUse", nil), ("PreToolUse", "AskUserQuestion"),
    ("PermissionRequest", nil), ("Notification", nil), ("Stop", nil), ("SessionEnd", nil),
  ]

  static var command: String { "\"\(Bundle.main.executablePath ?? "DitooStatus")\" --hook" }

  /// Our entries, plus the old Python prototype's, are recognized and replaced.
  static func isOurs(_ cmd: String) -> Bool { cmd.contains("DitooStatus") || cmd.contains("claude_status.py") }

  static func load() -> [String: Any] {
    guard let d = try? Data(contentsOf: Paths.claudeSettings),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
  }

  static var isInstalled: Bool {
    let hooks = load()["hooks"] as? [String: Any] ?? [:]
    return events.allSatisfy { e in
      groups(hooks[e.event]).contains { g in commands(g).contains(command) }
    }
  }

  private static func groups(_ v: Any?) -> [[String: Any]] { v as? [[String: Any]] ?? [] }
  private static func commands(_ g: [String: Any]) -> [String] {
    (g["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
  }

  static func install() throws { try edit(add: true) }

  /// Hooks pointing at an older copy of the app (it was moved or rebuilt elsewhere) are pointed here.
  static func repairIfMoved() {
    let hooks = load()["hooks"] as? [String: Any] ?? [:]
    let ours = hooks.values.flatMap { groups($0) }.flatMap { commands($0) }.filter { isOurs($0) }
    guard !ours.isEmpty, !isInstalled else { return }
    do { try install(); Log.write("hooks: pointed at \(command)") } catch { Log.write("hooks: repair failed: \(error)") }
  }
  static func uninstall() throws { try edit(add: false) }

  private static func edit(add: Bool) throws {
    var settings = load()
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for e in events {
      var gs = groups(hooks[e.event]).compactMap { g -> [String: Any]? in
        var g = g
        let kept = (g["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0["command"] as? String ?? "") }
        if kept.isEmpty { return nil }
        g["hooks"] = kept
        return g
      }
      if add {
        var g: [String: Any] = ["hooks": [["type": "command", "command": command, "async": true, "timeout": 10]]]
        if let m = e.matcher { g["matcher"] = m }
        gs.append(g)
      }
      hooks[e.event] = gs.isEmpty ? nil : gs
    }
    settings["hooks"] = hooks.isEmpty ? nil : hooks
    let fm = FileManager.default
    if fm.fileExists(atPath: Paths.claudeSettings.path) {
      let bak = Paths.claudeSettings.appendingPathExtension("bak-ditoostatus")
      try? fm.removeItem(at: bak)
      try fm.copyItem(at: Paths.claudeSettings, to: bak)
    } else {
      try fm.createDirectory(at: Paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
    try data.write(to: Paths.claudeSettings, options: .atomic)
  }
}
