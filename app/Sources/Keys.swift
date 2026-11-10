import Foundation

/// The Ditoo's key-light effect can't be set or read, only stepped (`23 00` previous, `23 01` next).
/// So we count: effect 0 is solid white, and every step we send moves the index by one.
/// The index is saved, so it survives app restarts. If the keys get out of step (changed on the
/// device itself), put them back on solid white and run `dev/ditoo keys at 0`.
///
/// Effects seen from solid white (stock firmware, 2026-11-10): 0 white · 1 orange chase ·
/// 2 yellow blink · 3 green with a bright green chase · 4 multicolor blink · 5 color cycle ·
/// 6 red/pink/orange blink · 7 pink/blue/purple blink · 8 yellow chase · 9 green blink ·
/// 10 turquoise chase · 11 blue-white blink · 12 color cycle · 13 pale blink · 14 blue/purple blink ·
/// 15 green chase · 16 turquoise blink. The list repeats its motions in groups of 7 with new colors.
final class KeyLights {
  private static let saved = "keyLightIndex"
  private let device: Device
  private(set) var index: Int
  private(set) var target: Int?
  private var timer: Timer?

  init(device: Device) {
    self.device = device
    index = UserDefaults.standard.integer(forKey: KeyLights.saved)  // 0 when never saved
  }

  /// Walk to `effect`, one step at a time (each step briefly shows the effects in between).
  func go(_ effect: Int) {
    let e = max(0, effect)
    guard e != target else { return }
    target = e
    guard e != index, timer == nil else { return }
    Log.write("keys: \(index) → \(e)")
    timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.tick() }
  }

  /// The keys are showing `effect` right now (re-sync after they were changed on the device).
  func calibrate(at effect: Int) {
    index = max(0, effect)
    save()
    target = nil  // the next state update walks from here
  }

  /// Manual previous/next (menu buttons), keeping the count right. Cancels any walk in progress,
  /// so the app doesn't step the keys back to its own choice.
  func nudge(_ by: Int) {
    guard by != 0, device.send(Proto.keyboardLight(by > 0 ? 1 : 0)) else { return }
    index = max(0, index + (by > 0 ? 1 : -1))
    save()
    stop()
    target = index
  }

  /// Stop walking (the app no longer controls the keys).
  func stop() {
    timer?.invalidate(); timer = nil
    target = nil
  }

  var status: String { "keys at \(index)" + (target.map { $0 == index ? "" : " → \($0)" } ?? "") }

  private func tick() {
    guard let t = target, t != index else { timer?.invalidate(); timer = nil; return }
    guard device.isConnected else { return }  // wait for the link; the target stays
    let up = t > index
    guard device.send(Proto.keyboardLight(up ? 1 : 0)) else { return }
    index += up ? 1 : -1
    save()
  }

  private func save() { UserDefaults.standard.set(index, forKey: KeyLights.saved) }
}
