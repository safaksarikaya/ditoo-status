import AppKit
import ServiceManagement
import SwiftUI

/// Shared state: settings, Bluetooth connection, screen manager.
final class AppModel: ObservableObject {
  /// One instance per process: SwiftUI may build the App struct more than once.
  static let shared = AppModel()
  @Published var config: Config {
    didSet {
      guard config != oldValue else { return }
      config.save()
      screen.config = config
      if config.deviceAddress != oldValue.deviceAddress || config.rfcommChannel != oldValue.rfcommChannel {
        device.connect(address: config.deviceAddress, channel: config.rfcommChannel)
      }
      if config.brightness != oldValue.brightness { device.send(Proto.brightness(config.brightness)) }
    }
  }
  let device = Device()
  let screen: ScreenManager
  let drawing = DrawModel()
  @Published var hooksInstalled = ClaudeHooks.isInstalled
  @Published var hookError: String?
  private var dev: DevServer?

  private init() {
    Log.write("starting")
    var cfg = Config.load()
    if cfg.deviceAddress.isEmpty, let d = Device.paired().first(where: { $0.name.lowercased().contains("ditoo") }) {
      cfg.deviceAddress = d.address  // first run: pick the paired Ditoo
      cfg.save()
    }
    config = cfg
    AgentVisuals.setUp()
    ClaudeHooks.repairIfMoved()
    hooksInstalled = ClaudeHooks.isInstalled
    screen = ScreenManager(device: device, config: cfg)
    screen.homeDrawing = { [drawing] in drawing.animation }
    drawing.onChange = { [screen] in if screen.config.home == .drawing { screen.refreshHome() } }
    device.connect(address: cfg.deviceAddress, channel: cfg.rfcommChannel)
    screen.start()
    dev = DevServer { [weak self] line in self?.devCommand(line) ?? "" }
    device.onReceive = { [weak self] b in self?.dev?.broadcast("rx: " + Hex.string(b)) }
    dev?.start()
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
      [device] _ in device.disconnect()  // free the channel so the next launch can connect
    }
  }

  /// Commands from the dev port (see Dev.swift).
  func devCommand(_ line: String) -> String {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    let arg = parts.count > 1 ? parts[1] : ""
    switch parts[0] {
    case "send":  // raw payload, framing is added: send 23 01
      guard let b = Hex.parse(arg) else { return "bad hex" }
      return device.send(b) ? "sent " + Hex.string(Proto.packet(b)) : "not connected"
    case "show": return screen.dev(show: arg)
    case "agent":  // agent <name> <working|waiting|done|end> [session]
      let w = arg.split(separator: " ").map(String.init)
      guard w.count == 2 || w.count == 3 else { return "agent <name> <working|waiting|done|end> [session]" }
      return AgentStore.record(agent: w[0], session: w.count == 3 ? w[2] : "default", state: w[1]) ?? "ok"
    case "login":  // login [on|off]: open at login
      do {
        if arg == "on" { try SMAppService.mainApp.register() } else if arg == "off" { try SMAppService.mainApp.unregister() }
      } catch { return "login: \(error.localizedDescription)" }
      return "open at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")"
    case "reload": config = Config.load(); return "config reloaded"
    case "status": return "\(device.status.label) | \(screen.devStatus)"
    case "reconnect": device.connect(address: config.deviceAddress, channel: config.rfcommChannel); return "ok"
    case "keys":  // keys | keys at <n> (the keys show effect n now) | keys prev | keys next
      let w = arg.split(separator: " ").map(String.init)
      switch w.first {
      case "at": guard w.count > 1, let n = Int(w[1]) else { return "keys at <n>" }; screen.keys.calibrate(at: n)
      case "prev": screen.keys.nudge(-1)
      case "next": screen.keys.nudge(1)
      case nil: break
      default: return "keys | keys at <n> | keys prev | keys next"
      }
      return screen.keys.status
    default: return "commands: send <hex> | show clock|home|claude|agent <name>|charging|battery | agent <name> <state> [session] | keys [at <n>|prev|next] | login [on|off] | reload | status | reconnect"
    }
  }

  func setHooks(_ on: Bool) {
    do {
      try on ? ClaudeHooks.install() : ClaudeHooks.uninstall()
      hookError = nil
    } catch { hookError = error.localizedDescription }
    hooksInstalled = ClaudeHooks.isInstalled
  }
}

@main
enum Main {
  static func main() {
    // Claude Code hooks run this binary with --hook: record the state and exit before any UI or Bluetooth starts.
    if CommandLine.arguments.contains("--hook") { ClaudeSessions.runHook() }
    // Other agents: DitooStatus --agent <name> <state> [session]
    if let i = CommandLine.arguments.firstIndex(of: "--agent") { AgentStore.runCLI(Array(CommandLine.arguments[(i + 1)...])) }
    DitooStatusApp.main()
  }
}

struct DitooStatusApp: App {
  @ObservedObject private var model = AppModel.shared

  var body: some Scene {
    MenuBarExtra {
      MenuPanel().environmentObject(model).environmentObject(model.device).environmentObject(model.screen)
    } label: {
      MenuIcon().environmentObject(model.screen).environmentObject(model.device)
    }
    .menuBarExtraStyle(.window)

    Window("Ditoo Status Settings", id: "settings") {
      SettingsView().environmentObject(model).environmentObject(model.device).environmentObject(model.screen)
    }
    .windowResizability(.contentSize)

    Window("Ditoo Drawing", id: "draw") {
      DrawView().environmentObject(model).environmentObject(model.drawing).environmentObject(model.screen)
    }
    .windowResizability(.contentSize)
  }
}

// MARK: - Menu bar

struct MenuIcon: View {
  @EnvironmentObject var screen: ScreenManager
  @EnvironmentObject var device: Device
  var body: some View {
    let mood = ClaudeState.mood(of: screen.sessions.map(\.state))
    let name = !device.isConnected ? "square.grid.3x3.square.badge.ellipsis"
      : mood == .waiting ? "exclamationmark.square.fill" : "square.grid.3x3.fill"
    Image(systemName: name)
  }
}

struct MenuPanel: View {
  @EnvironmentObject var model: AppModel
  @EnvironmentObject var device: Device
  @EnvironmentObject var screen: ScreenManager
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        PixelPreview(anim: screen.preview, placeholder: screen.nowShowing)
          .frame(width: 112, height: 112)
        VStack(alignment: .leading, spacing: 4) {
          Text("Ditoo Status").font(.headline)
          Label(device.status.label, systemImage: device.isConnected ? "dot.radiowaves.left.and.right" : "bolt.horizontal.circle")
            .foregroundStyle(device.isConnected ? .green : .secondary)
            .font(.caption)
          Text(device.name.isEmpty ? "No device" : device.name).font(.caption).foregroundStyle(.secondary)
          Text("Showing: \(screen.nowShowing)").font(.caption).foregroundStyle(.secondary)
        }
      }

      Divider()
      Text("Agents").font(.subheadline.bold())
      if screen.sessions.isEmpty {
        Text(model.hooksInstalled ? "No active sessions" : "Hooks not installed — see Settings")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        ForEach(screen.sessions, id: \.key) { s in
          HStack(spacing: 6) {
            Circle().fill(color(Screens.dotColors[s.state]!)).frame(width: 8, height: 8)
            Text(screen.visuals.name(s.agent)).font(.caption)
            Text(s.state.rawValue.capitalized).font(.caption)
            Text(String(s.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
          }
        }
      }

      Divider()
      Text("Batteries").font(.subheadline.bold())
      if screen.batteries.isEmpty {
        Text("No Bluetooth accessories reporting").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(screen.batteries.sorted(by: { $0.value < $1.value }), id: \.key) { name, pct in
        HStack {
          Image(systemName: screen.isKeyboard(name) ? "keyboard" : "computermouse")
          Text(name).font(.caption).lineLimit(1)
          Spacer()
          if screen.charging.contains(name) { Image(systemName: "bolt.fill").foregroundStyle(.yellow).font(.caption) }
          Text("\(pct)%").font(.caption.monospacedDigit()).foregroundStyle(color(Screens.batteryColor(pct)))
        }
      }

      Divider()
      HStack {
        Button("Home") { screen.goHome() }
        Button("Clock") { screen.showClock() }
        Menu("Test") {
          Button("Claude working") { screen.testClaude([.working]) }
          Button("Claude waiting for you") { screen.testClaude([.waiting, .working]) }
          Button("Claude done") { screen.testClaude([.done]) }
          Divider()
          Button("Mouse battery") { screen.testBattery(keyboard: false) }
          Button("Keyboard battery") { screen.testBattery(keyboard: true) }
          Button("Mouse charging") { screen.testCharging(keyboard: false) }
          Button("Keyboard charging") { screen.testCharging(keyboard: true) }
        }
        .fixedSize()
      }
      HStack {
        Button("Draw…") {
          NSApp.activate(ignoringOtherApps: true)
          openWindow(id: "draw")
        }
        Button("Settings…") {
          NSApp.activate(ignoringOtherApps: true)
          openWindow(id: "settings")
        }
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
      }
    }
    .padding(14)
    .frame(width: 300)
  }
}

func color(_ c: RGB) -> Color { Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255) }

/// Renders what the Ditoo is showing, animated.
struct PixelPreview: View {
  let anim: Animation?
  let placeholder: String

  var body: some View {
    if let anim, !anim.frames.isEmpty {
      TimelineView(.animation) { ctx in
        Canvas { g, size in
          let px = frame(anim, at: ctx.date)
          let cell = size.width / 16
          g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
          for y in 0..<16 {
            for x in 0..<16 {
              let c = px[y * 16 + x]
              let r = CGRect(x: CGFloat(x) * cell + 0.5, y: CGFloat(y) * cell + 0.5, width: cell - 1, height: cell - 1)
              g.fill(Path(r), with: .color(c == .black ? Color(white: 0.09) : color(c)))
            }
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
    } else {
      RoundedRectangle(cornerRadius: 6).fill(Color.black)
        .overlay(Text(placeholder).font(.caption2).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).padding(6))
    }
  }

  private func frame(_ a: Animation, at d: Date) -> [RGB] {
    let total = a.frames.reduce(0) { $0 + max($1.ms, 1) }
    guard a.frames.count > 1, total > 0 else { return a.frames[0].px }
    var t = Int(d.timeIntervalSinceReferenceDate * 1000) % total
    for f in a.frames {
      t -= max(f.ms, 1)
      if t < 0 { return f.px }
    }
    return a.frames[0].px
  }
}
