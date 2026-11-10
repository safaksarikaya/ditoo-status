import ServiceManagement
import SwiftUI

/// View-local state (an ObservableObject: the @State macro needs Xcode's SwiftUI plugin).
final class SettingsLocal: ObservableObject {
  @Published var paired = Device.paired()
  @Published var loginItem = SMAppService.mainApp.status == .enabled
  @Published var loginError: String?
}

struct SettingsView: View {
  @EnvironmentObject var model: AppModel
  @EnvironmentObject var device: Device
  @StateObject private var local = SettingsLocal()
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Form {
      deviceSection
      Section("Home screen") {
        Picker("Show between events", selection: $model.config.home) {
          Text("My image from the Divoom app").tag(Config.Home.design)
          Text("Clock").tag(Config.Home.clock)
          Text("My drawing").tag(Config.Home.drawing)
        }
        Button("Open drawing editor…") {
          NSApp.activate(ignoringOtherApps: true)
          openWindow(id: "draw")
        }
      }
      cycleSection
      clockSection
      claudeSection
      agentsSection
      batterySection
      keyboardLightSection
      Section("General") {
        Toggle("Open at login", isOn: $local.loginItem)
          .onChange(of: local.loginItem) { _, on in
            do {
              try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
              local.loginError = nil
            } catch { local.loginError = error.localizedDescription }
          }
        if let e = local.loginError { Text(e).font(.caption).foregroundStyle(.red) }
        LabeledContent("Log file", value: Paths.log.path).font(.caption)
      }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 680)
  }

  // MARK: sections

  private var deviceSection: some View {
    Section("Device") {
      Picker("Ditoo", selection: $model.config.deviceAddress) {
        if !local.paired.contains(where: { $0.address == model.config.deviceAddress }) {
          Text(model.config.deviceAddress.isEmpty ? "None" : model.config.deviceAddress).tag(model.config.deviceAddress)
        }
        ForEach(local.paired, id: \.address) { d in Text("\(d.name)  (\(d.address))").tag(d.address) }
      }
      HStack {
        Circle().fill(device.isConnected ? Color.green : Color.orange).frame(width: 8, height: 8)
        Text(device.status.label).font(.caption)
        Spacer()
        Button("Refresh list") { local.paired = Device.paired() }
        Button("Reconnect") { device.connect(address: model.config.deviceAddress, channel: model.config.rfcommChannel) }
      }
      Text("Pair the Ditoo in macOS Bluetooth settings first. Pick the “…-audio” entry; the screen is reached over the same connection.")
        .font(.caption).foregroundStyle(.secondary)
      LabeledContent("Brightness") {
        Slider(value: intBinding($model.config.brightness), in: 5...100, step: 5)
      }
    }
  }

  private var cycleSection: some View {
    Section("Rotation") {
      Toggle("Rotate clock → my image → agents", isOn: $model.config.cycle.enabled)
      Stepper(secLabel("Clock", model.config.cycle.clockSec), value: $model.config.cycle.clockSec, in: 0...600, step: 5)
      Stepper(secLabel("My image", model.config.cycle.homeSec), value: $model.config.cycle.homeSec, in: 0...600, step: 5)
      Stepper(secLabel("Each agent (only while it works or waits)", model.config.cycle.claudeSec),
              value: $model.config.cycle.claudeSec, in: 0...600, step: 1)
      Text("0 skips that screen. The speed of your GIF itself is set in the Divoom app.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func secLabel(_ name: String, _ s: Int) -> String { s == 0 ? "\(name): skipped" : "\(name): \(s) s" }

  private var clockSection: some View {
    Section("Clock") {
      Toggle("Show the clock from time to time", isOn: $model.config.clock.enabled)
      Stepper("Every \(model.config.clock.everyMin) min", value: $model.config.clock.everyMin, in: 1...240)
      Stepper("For \(model.config.clock.showSec) s", value: $model.config.clock.showSec, in: 3...120)
      ColorPicker("Color", selection: colorBinding($model.config.clock.color), supportsOpacity: false)
      Toggle("24-hour", isOn: $model.config.clock.h24)
      Stepper("Style \(model.config.clock.style)", value: $model.config.clock.style, in: 0...5)
    }
  }

  private var claudeSection: some View {
    Section("Claude Code") {
      Toggle("Show Claude Code status", isOn: $model.config.claude.enabled)
      Stepper("Show for \(model.config.claude.showSec) s", value: $model.config.claude.showSec, in: 3...60)
      Toggle("Show when Claude starts working", isOn: $model.config.claude.showWorking)
      Stepper(model.config.claude.workingEveryMin == 0 ? "While working: no reminders"
              : "While working: remind every \(model.config.claude.workingEveryMin) min",
              value: $model.config.claude.workingEveryMin, in: 0...60)
      Toggle("Keep the mascot up while Claude waits for you", isOn: $model.config.claude.waitingSticky)
      HStack {
        Image(systemName: model.hooksInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(model.hooksInstalled ? .green : .orange)
        Text(model.hooksInstalled ? "Hooks installed in ~/.claude/settings.json" : "Hooks not installed")
          .font(.caption)
        Spacer()
        if model.hooksInstalled {
          Button("Remove hooks") { model.setHooks(false) }
        } else {
          Button("Install hooks") { model.setHooks(true) }
        }
      }
      if let e = model.hookError { Text(e).font(.caption).foregroundStyle(.red) }
      Text("The hooks only record each session's state to a local file; they don't call the model and cost no tokens. A backup of settings.json is kept next to it.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var agentsSection: some View {
    Section("Agents") {
      Text("Other AI agents report their state with the ditoo-agent command and bring their own screens: a folder per agent with working.gif, waiting.gif and done.gif. The folder's README.txt explains it. Claude's mascot lives there too, ready to restyle.")
        .font(.caption).foregroundStyle(.secondary)
      LabeledContent("Command", value: "\"\(Paths.agentCommand.path)\" <agent> <working|waiting|done|end> [session]")
        .font(.caption).textSelection(.enabled)
      HStack {
        Button("Open agents folder") { NSWorkspace.shared.open(Paths.agents) }
        Button("Restore Claude's visuals") { AgentVisuals.exportClaude() }
      }
    }
  }

  private var batterySection: some View {
    Section("Low battery alerts") {
      Toggle("Alert for Bluetooth mice and keyboards", isOn: $model.config.battery.enabled)
      Toggle("Show when charging", isOn: $model.config.battery.showCharging)
      Text("macOS doesn't report charging for Bluetooth accessories, so it's inferred from a rising percentage between checks.")
        .font(.caption).foregroundStyle(.secondary)
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
        GridRow {
          Text("At or below").font(.caption.bold())
          Text("Every (min)").font(.caption.bold())
          Text("Times (0 = ∞)").font(.caption.bold())
          Text("Show (s)").font(.caption.bold())
          Text("")
        }
        ForEach(model.config.battery.tiers.indices, id: \.self) { i in
          GridRow {
            numberField($model.config.battery.tiers[i].maxPct, suffix: "%")
            numberField($model.config.battery.tiers[i].everyMin)
            numberField($model.config.battery.tiers[i].times)
            numberField($model.config.battery.tiers[i].showSec)
            Button { model.config.battery.tiers.remove(at: i) } label: { Image(systemName: "minus.circle") }
              .buttonStyle(.borderless)
          }
        }
      }
      Button("Add tier") {
        model.config.battery.tiers.append(.init(maxPct: 15, everyMin: 15, times: 3, showSec: 6))
      }
      TextField("Keyboard name contains (comma separated)", text: listBinding($model.config.battery.keyboardWords))
        .font(.caption)
    }
  }

  private var keyboardLightSection: some View {
    Section("Ditoo key lights (experimental)") {
      HStack {
        Button("Previous effect") { pickKeys(-1) }
        Button("Next effect") { pickKeys(1) }
        Button("On / off") { device.send(Proto.keyboardLight(2)) }
      }
      Toggle("Let the app control the key lights", isOn: Binding(
        get: { model.config.keys.enabled },
        set: { model.config.keys.enabled = $0; if !$0 { model.screen.keys.stop() } }))
      Toggle("Keep the keys on one effect", isOn: Binding(
        get: { model.config.keys.fixed >= 0 },
        set: { model.config.keys.fixed = $0 ? max(0, model.screen.keys.index) : -1 }))
      if model.config.keys.fixed >= 0 {
        Stepper("Effect \(model.config.keys.fixed)", value: $model.config.keys.fixed, in: 0...16)
      } else {
        Text("Idle \(model.config.keys.idle) · working \(model.config.keys.working) · waiting \(model.config.keys.waiting) · low battery \(model.config.keys.lowBattery) · charging \(model.config.keys.charging) · full \(model.config.keys.full)")
          .font(.caption)
      }
      Button("The keys show solid white now (re-sync)") { model.screen.keys.calibrate(at: 0) }
      Text("Previous / next keeps the keys on the effect you picked; turn off \"Keep the keys on one effect\" to let them follow Claude again. The Ditoo can't report its key effect, so the app counts steps from solid white. If you change the effect on the device itself, step back to solid white and press re-sync.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  /// A manual pick pins the keys there, so Claude's state changes don't move them.
  private func pickKeys(_ by: Int) {
    model.screen.keys.nudge(by)
    if model.config.keys.enabled { model.config.keys.fixed = model.screen.keys.index }
  }

  // MARK: bindings

  private func numberField(_ b: Binding<Int>, suffix: String = "") -> some View {
    HStack(spacing: 2) {
      TextField("", value: b, format: .number).frame(width: 52).multilineTextAlignment(.trailing)
      if !suffix.isEmpty { Text(suffix).font(.caption) }
    }
  }

  private func intBinding(_ b: Binding<Int>) -> Binding<Double> {
    Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int($0) })
  }

  private func colorBinding(_ b: Binding<RGB>) -> Binding<Color> {
    Binding(get: { color(b.wrappedValue) }, set: { c in
      let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
      b.wrappedValue = RGB(Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
    })
  }

  private func listBinding(_ b: Binding<[String]>) -> Binding<String> {
    Binding(get: { b.wrappedValue.joined(separator: ", ") }, set: {
      b.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    })
  }
}
