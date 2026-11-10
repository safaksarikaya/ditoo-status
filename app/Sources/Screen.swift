import Foundation

// MARK: - Settings

struct Config: Codable, Equatable {
  struct Clock: Codable, Equatable {
    var enabled = true, everyMin = 10, showSec = 15
    var color = RGB(255, 255, 255), style = 0, h24 = true
  }
  struct Claude: Codable, Equatable {
    var enabled = true, showSec = 8
    var showWorking = true, workingEveryMin = 2  // 0 = only on state changes
    var waitingSticky = true  // keep the mascot up while a session waits for you
  }
  struct Tier: Codable, Equatable {
    var maxPct: Int, everyMin: Int
    var times: Int  // 0 = unlimited
    var showSec: Int
  }
  struct Battery: Codable, Equatable {
    var enabled = true, checkMin = 2
    var showCharging = true  // the percentage went up since the last check
    var tiers = [Tier(maxPct: 20, everyMin: 30, times: 3, showSec: 6),
                 Tier(maxPct: 10, everyMin: 10, times: 6, showSec: 8),
                 Tier(maxPct: 5, everyMin: 2, times: 0, showSec: 10)]
    var keyboardWords = ["keyboard", "nuphy", "halo", "keychron"]
    var ignore = ["AirPods", "Ditoo", "InternalBattery"]
  }
  /// Clock → home (your image/GIF) → Claude mascot, round and round. Alerts interrupt it.
  struct Cycle: Codable, Equatable {
    var enabled = true, clockSec = 10, homeSec = 30, claudeSec = 8  // 0 skips that slot
  }
  /// Key-light effect numbers (see Keys.swift) for each state; -1 leaves the keys alone.
  struct Keys: Codable, Equatable {
    var enabled = true
    var fixed = -1  // >= 0: always this effect, the keys ignore Claude and battery
    var idle = 4, working = 1, waiting = 2  // multicolor blink · orange chase · yellow blink
    var lowBattery = 6, charging = 3, full = 9  // red/pink/orange blink · green chase · green blink
  }
  enum Home: String, Codable, CaseIterable { case design, clock, drawing }

  var deviceAddress = ""
  var rfcommChannel = 1
  var home = Home.design
  var brightness = 80
  var clock = Clock()
  var claude = Claude()
  var battery = Battery()
  var cycle = Cycle()
  var keys = Keys()

  /// Saved values over the defaults, so settings added in a newer version don't reset the file.
  static func load() -> Config {
    guard let d = try? Data(contentsOf: Paths.config) else { return Config() }
    do {
      let saved = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
      let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any] ?? [:]
      let merged = try JSONSerialization.data(withJSONObject: merge(defaults, saved))
      return try JSONDecoder().decode(Config.self, from: merged)
    } catch {
      Log.write("config.json unreadable, using defaults: \(error)")
      return Config()
    }
  }

  private static func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
    var out = a
    for (k, v) in b {
      if let av = a[k] as? [String: Any], let bv = v as? [String: Any] { out[k] = merge(av, bv) } else { out[k] = v }
    }
    return out
  }

  func save() {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? e.encode(self).write(to: Paths.config, options: .atomic)
  }
}

// MARK: - Batteries

enum Batteries {
  /// Bluetooth accessory batteries from `pmset -g accps`: name → percent.
  static func read(ignore: [String]) -> [String: Int] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "accps"]
    let pipe = Pipe(); p.standardOutput = pipe
    guard (try? p.run()) != nil else { return [:] }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    var res: [String: Int] = [:]
    let re = try! NSRegularExpression(pattern: #"-(.+?) \(id=\d+\)\s+(\d+)%"#)
    for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
      guard let n = Range(m.range(at: 1), in: out), let v = Range(m.range(at: 2), in: out) else { continue }
      let name = out[n].trimmingCharacters(in: .whitespaces)
      if !ignore.contains(where: { name.contains($0) }) { res[name] = Int(out[v]) }
    }
    return res
  }
}

// MARK: - Screen manager

/// Owns the Ditoo screen. Home is your own image (design channel); Claude events, battery alerts and
/// the clock interrupt it for a few seconds, then it returns home.
final class ScreenManager: ObservableObject {
  enum Kind: Int, Comparable {
    case claude, battery, clock, test, cycle  // lower = higher priority
    static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
  }
  struct Item {
    var kind: Kind; var anim: Animation?; var secs: Double; var label: String
    var keys: Int? = nil  // key-light effect while this is on screen
  }

  @Published private(set) var nowShowing = "Home"
  @Published private(set) var preview: Animation?  // what's on the Ditoo, if we drew it
  @Published private(set) var sessions: [AgentSession] = []
  @Published private(set) var batteries: [String: Int] = [:]
  @Published private(set) var charging: Set<String> = []
  /// The user's drawing for the "My drawing" home screen.
  var homeDrawing: () -> Animation? = { nil }

  let device: Device
  let keys: KeyLights
  let visuals = AgentVisuals()
  var config: Config

  private var current: (kind: Kind, until: Date)?
  private var queue: [Item] = []
  private var needHome = true
  private var nextClock = Date().addingTimeInterval(60)
  private var nextBattery = Date.distantPast
  private var nextWorking = Date.distantPast
  private var nextTimeSync = Date.distantPast
  private var batSeen: [String: (tier: Int, count: Int, last: Date)] = [:]
  private var lastPct: [String: Int] = [:]
  private var fullShown: Set<String> = []
  private var chargeShown: [String: Date] = [:]
  private var agentPrev: [String: ClaudeState] = [:]
  private var waiting = false
  private var alertKeys: Int?  // key effect of the alert on screen
  private var timer: Timer?

  init(device: Device, config: Config) {
    self.device = device
    self.keys = KeyLights(device: device)
    self.config = config
    device.onConnect = { [weak self] in
      guard let self else { return }
      self.nextTimeSync = .distantPast
      self.needHome = true
      if self.current?.kind == .cycle { self.current = nil }  // redraw the slot after a reconnect
      self.device.send(Proto.brightness(self.config.brightness))
    }
  }

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.step() }
  }

  func isKeyboard(_ name: String) -> Bool {
    let n = name.lowercased()
    return config.battery.keyboardWords.contains { n.contains($0.lowercased()) }
  }

  // MARK: manual actions (menu)

  func showNow(_ item: Item) {
    queue.removeAll { $0.kind == item.kind }
    queue.insert(item, at: 0)
    current = nil
  }

  func testClaude(_ states: [ClaudeState]) {
    showNow(Item(kind: .test, anim: visuals.animation("claude", states) ?? Screens.claude(states), secs: 8, label: "Claude (test)"))
  }

  func testBattery(keyboard: Bool) {
    showNow(Item(kind: .test, anim: Screens.battery(isKeyboard: keyboard, pct: keyboard ? 9 : 15),
                 secs: 6, label: "Battery (test)", keys: config.keys.lowBattery))
  }

  func testCharging(keyboard: Bool) {
    showNow(Item(kind: .test, anim: Screens.charging(isKeyboard: keyboard, pct: 42), secs: 6, label: "Charging (test)",
                 keys: config.keys.charging))
  }

  func show(_ anim: Animation, secs: Double, label: String) { showNow(Item(kind: .test, anim: anim, secs: secs, label: label)) }

  /// Redraw home now if it's on screen (e.g. the drawing changed).
  func refreshHome() { if current == nil { needHome = true } }

  func showClock() { showNow(Item(kind: .test, anim: nil, secs: Double(config.clock.showSec), label: "Clock")) }
  func goHome() { queue.removeAll(); current = nil; needHome = true }

  // MARK: sources

  private func enqueue(_ item: Item) {
    if item.kind == .claude { queue.removeAll { $0.kind == .claude } }  // latest state wins
    queue.append(item)
    queue.sort { $0.kind < $1.kind }
  }

  /// An agent's screen for its current sessions; nil when the agent has no visuals.
  private func agentItem(_ agent: String) -> Item? {
    guard let a = visuals.animation(agent, sessions.filter { $0.agent == agent }.map(\.state)) else { return nil }
    return Item(kind: .claude, anim: a, secs: Double(config.claude.showSec), label: visuals.name(agent))
  }

  /// Agents with a session that's working or waiting, in display order.
  private var busyAgents: [String] {
    var out: [String] = []
    for s in sessions where (s.state == .working || s.state == .waiting) && !out.contains(s.agent) { out.append(s.agent) }
    return out
  }

  private func pollAgents(_ now: Date) {
    sessions = AgentStore.read()
    let c = config.claude
    guard c.enabled else { return }
    var show: String?  // agent whose screen should come up; a waiting one wins
    let cycling = config.cycle.enabled && config.cycle.claudeSec > 0  // busy agents come round anyway
    for s in sessions where s.state != agentPrev[s.key] {
      if cycling ? s.state == .waiting : (s.state != .working || c.showWorking) {
        if show == nil || s.state == .waiting { show = s.agent }
      }
    }
    agentPrev = Dictionary(uniqueKeysWithValues: sessions.map { ($0.key, $0.state) })
    // Long tasks don't change state; remind every few minutes while something is working.
    if !cycling, c.workingEveryMin > 0, now >= nextWorking, let w = sessions.first(where: { $0.state == .working }) {
      show = show ?? w.agent
    }
    let waiter = sessions.first { $0.state == .waiting && agentItem($0.agent) != nil }?.agent
    waiting = c.waitingSticky && waiter != nil
    if waiting, current?.kind != .claude, !queue.contains(where: { $0.kind == .claude }) { show = show ?? waiter }
    guard let agent = show, let item = agentItem(agent) else { return }
    nextWorking = now.addingTimeInterval(Double(c.workingEveryMin) * 60)
    if current?.kind == .claude {  // already up: redraw and extend
      render(item)
      current = (.claude, now.addingTimeInterval(Double(c.showSec)))
    } else {
      enqueue(item)
    }
  }

  private func pollBattery(_ now: Date) {
    let b = config.battery
    guard now >= nextBattery else { return }
    nextBattery = now.addingTimeInterval(60)  // cheap; alert timing comes from the tiers
    batteries = Batteries.read(ignore: b.ignore)
    guard b.enabled else { return }
    let tiers = b.tiers.sorted { $0.maxPct < $1.maxPct }  // lowest threshold first
    for (name, pct) in batteries {
      // macOS doesn't report charging for these accessories; a rising percentage means charging.
      if let last = lastPct[name] {
        if pct > last {
          if charging.insert(name).inserted { Log.write("charging: \(name) \(pct)%") }
          // Re-show on each rise, at most every 3 min, so it isn't missed.
          if b.showCharging, pct < 100, now.timeIntervalSince(chargeShown[name] ?? .distantPast) >= 180 {
            chargeShown[name] = now
            enqueue(Item(kind: .battery, anim: Screens.charging(isKeyboard: isKeyboard(name), pct: pct),
                         secs: 10, label: "\(name) charging", keys: config.keys.charging))
          }
        } else if pct < last {
          charging.remove(name); fullShown.remove(name); chargeShown[name] = nil
        }
      }
      lastPct[name] = pct
      if charging.contains(name) {  // no low-battery alerts while charging
        batSeen[name] = nil
        if pct >= 100, b.showCharging, fullShown.insert(name).inserted {
          enqueue(Item(kind: .battery, anim: Screens.charging(isKeyboard: isKeyboard(name), pct: 100),
                       secs: 10, label: "\(name) full", keys: config.keys.full))
        }
        continue
      }
      guard let idx = tiers.firstIndex(where: { pct <= $0.maxPct }) else {
        batSeen[name] = nil  // charged: reset counters
        continue
      }
      let t = tiers[idx]
      var st = batSeen[name] ?? (idx, 0, .distantPast)
      if st.tier != idx { st = (idx, 0, .distantPast) }
      if (t.times == 0 || st.count < t.times), now.timeIntervalSince(st.last) >= Double(t.everyMin) * 60 {
        st.count += 1; st.last = now
        Log.write("battery alert: \(name) \(pct)% (#\(st.count))")
        enqueue(Item(kind: .battery, anim: Screens.battery(isKeyboard: isKeyboard(name), pct: pct),
                     secs: Double(t.showSec), label: "\(name) \(pct)%", keys: config.keys.lowBattery))
      }
      batSeen[name] = st
    }
  }

  private func pollClock(_ now: Date) {
    let ck = config.clock
    guard ck.enabled, !config.cycle.enabled, config.home != .clock, now >= nextClock else { return }
    nextClock = now.addingTimeInterval(Double(ck.everyMin) * 60)
    enqueue(Item(kind: .clock, anim: nil, secs: Double(ck.showSec), label: "Clock"))
  }

  // MARK: drawing

  private func sendClock() {
    let ck = config.clock
    device.screen(Proto.disableGalleryRotation, Proto.clock(style: ck.style, h24: ck.h24, color: ck.color))
  }

  private func render(_ item: Item) {
    if let a = item.anim { device.show(a) } else { sendClock() }
    preview = item.anim
    nowShowing = item.label
    alertKeys = item.keys
  }

  private func renderHome() {
    preview = nil
    switch config.home {
    case .clock: sendClock(); nowShowing = "Clock (home)"
    case .drawing:
      if let a = homeDrawing() { device.show(a); preview = a; nowShowing = "Your drawing"; return }
      fallthrough
    case .design: device.screen(Proto.designChannel); nowShowing = "Your image"
    }
  }

  private var lastSlot: String?
  private var pendingSlot: String?  // dev port: show this slot next

  /// Rotation: clock → home → each busy agent that has visuals. Slots set to 0 s are skipped.
  private func nextSlot(_ now: Date) {
    let cy = config.cycle
    var slots: [(name: String, secs: Int)] = [("clock", cy.clockSec), ("home", cy.homeSec)]
    if config.claude.enabled {
      for a in busyAgents where visuals.canShow(a) { slots.append(("agent:" + a, cy.claudeSec)) }
    }
    guard slots.contains(where: { $0.secs > 0 }) else { if needHome { renderHome(); needHome = false }; return }
    var pick = slots.first { $0.name == pendingSlot && $0.secs > 0 }
    if pick == nil {
      let order = slots.firstIndex { $0.name == lastSlot }.map { Array(slots[($0 + 1)...] + slots[...$0]) } ?? slots
      pick = order.first { $0.secs > 0 }
    }
    guard let p = pick else { return }
    pendingSlot = nil
    lastSlot = p.name
    switch p.name {
    case "clock": sendClock(); preview = nil; nowShowing = "Clock"
    case "home": renderHome()
    default:
      guard let item = agentItem(String(p.name.dropFirst(6))), let a = item.anim else { return }
      device.show(a); preview = a; nowShowing = item.label
    }
    needHome = false
    current = (.cycle, now.addingTimeInterval(Double(p.secs)))
  }

  /// Keys follow the screen: an alert's own effect while it's up, otherwise the Claude state.
  private func updateKeys() {
    let k = config.keys
    guard k.enabled else { return }
    if k.fixed >= 0 { keys.go(k.fixed); return }
    let alert = current.map { $0.kind != .cycle } == true ? alertKeys : nil
    // An agent's agent.json can pick its own effects.
    let effect: Int
    if let a = alert { effect = a }
    else if let w = sessions.first(where: { $0.state == .waiting }) { effect = visuals.info(w.agent).keys?["waiting"] ?? k.waiting }
    else if let w = sessions.first(where: { $0.state == .working }) { effect = visuals.info(w.agent).keys?["working"] ?? k.working }
    else { effect = k.idle }
    if effect >= 0 { keys.go(effect) }
  }

  /// Dev port: jump the cycle / show a screen now.
  func dev(show what: String) -> String {
    switch what {
    case "clock", "home": pendingSlot = what
    case "gif": pendingSlot = "home"
    case "claude": pendingSlot = "agent:claude"
    case _ where what.hasPrefix("agent "): pendingSlot = "agent:" + what.dropFirst(6)
    case "charging": testCharging(keyboard: true); return "ok"
    case "battery": testBattery(keyboard: true); return "ok"
    default: return "unknown screen (clock|home|claude|agent <name>|charging|battery)"
    }
    queue.removeAll(); current = nil; needHome = true
    if !config.cycle.enabled { renderHome() }
    return "ok"
  }

  var devStatus: String {
    "showing=\(nowShowing) \(keys.status) sessions=\(sessions.map { "\($0.agent):\($0.state.rawValue)" }) batteries=\(batteries) charging=\(charging.sorted())"
  }

  private func step() {
    let now = Date()
    pollAgents(now)
    pollBattery(now)
    pollClock(now)
    if current?.kind == .claude, waiting { current = (.claude, now.addingTimeInterval(1)) }  // hold while waiting
    if let c = current, now >= c.until { current = nil; needHome = true }
    defer { updateKeys() }
    guard device.isConnected else { return }
    if now >= nextTimeSync {  // keep the Ditoo's clock in sync with the Mac
      device.send(Proto.setTime())
      nextTimeSync = now.addingTimeInterval(6 * 3600)
    }
    // The clock can be interrupted; a waiting Claude screen only by a battery alert.
    let cur = current?.kind
    if let head = queue.first,
       cur == nil || cur == .cycle || (cur == .clock && head.kind != .clock) || (cur == .claude && waiting && head.kind == .battery) {
      queue.removeFirst()
      Log.write("show: \(head.label)")
      render(head)
      current = (head.kind, Date().addingTimeInterval(head.secs))
    } else if current == nil, config.cycle.enabled {
      nextSlot(now)
    } else if current == nil, needHome {
      renderHome()
      needHome = false
    }
  }
}
