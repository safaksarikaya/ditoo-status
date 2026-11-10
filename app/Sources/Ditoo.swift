import Foundation
import IOBluetooth

/// Divoom Ditoo protocol (classic Bluetooth, RFCOMM). Payload = command byte + arguments;
/// `packet` adds the 01 LEN … CHECKSUM 02 framing. Verified on a Ditoo Plus.
enum Proto {
  static func packet(_ payload: [UInt8]) -> [UInt8] {
    let len = payload.count + 2
    var body: [UInt8] = [UInt8(len & 0xff), UInt8(len >> 8)] + payload
    let sum = body.reduce(0) { ($0 + Int($1)) & 0xffff }
    body += [UInt8(sum & 0xff), UInt8(sum >> 8)]
    return [0x01] + body + [0x02]
  }

  /// One image frame: AA len(2) time(2) 00 ncolors palette bits (LSB-first).
  static func frame(_ px: [RGB], ms: Int) -> [UInt8] {
    var palette: [RGB] = [], index: [RGB: Int] = [:], idx: [Int] = []
    for p in px {
      if let i = index[p] { idx.append(i) } else {
        index[p] = palette.count; idx.append(palette.count); palette.append(p)
      }
    }
    let n = palette.count
    let bpp = n > 1 ? max(1, Int(ceil(log2(Double(n))))) : 1
    var bits: [UInt8] = [], acc = 0, nb = 0
    for i in idx {
      acc |= i << nb; nb += bpp
      while nb >= 8 { bits.append(UInt8(acc & 0xff)); acc >>= 8; nb -= 8 }
    }
    if nb > 0 { bits.append(UInt8(acc & 0xff)) }
    var body: [UInt8] = [UInt8(ms & 0xff), UInt8((ms >> 8) & 0xff), 0x00, UInt8(n % 256)]
    for c in palette { body += [c.r, c.g, c.b] }
    body += bits
    let flen = 3 + body.count
    return [0xAA, UInt8(flen & 0xff), UInt8(flen >> 8)] + body
  }

  static func image(_ px: [RGB]) -> [UInt8] { [0x44, 0x00, 0x0A, 0x0A, 0x04] + frame(px, ms: 0) }

  /// 0x49 animation upload in 200-byte chunks.
  static func animation(_ a: Animation) -> [[UInt8]] {
    let data = a.frames.flatMap { frame($0.px, ms: $0.ms) }
    let total: [UInt8] = [UInt8(data.count & 0xff), UInt8(data.count >> 8)]
    return stride(from: 0, to: data.count, by: 200).enumerated().map { i, o in
      [0x49] + total + [UInt8(i)] + Array(data[o..<min(o + 200, data.count)])
    }
  }

  static let designChannel: [UInt8] = [0x45, 0x05]  // the user's own image from the Divoom app
  static let disableGalleryRotation: [UInt8] = [0x26, 0x00]

  static func clock(style: Int, h24: Bool, color: RGB) -> [UInt8] {
    [0x45, 0x00, h24 ? 1 : 0, UInt8(clamping: style), 0x01, 0x00, 0x00, 0x00, color.r, color.g, color.b]
  }

  static func setTime(_ d: Date = Date()) -> [UInt8] {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: d)
    let y = c.year!
    return [0x18, UInt8(y % 100), UInt8(y / 100), UInt8(c.month!), UInt8(c.day!),
            UInt8(c.hour!), UInt8(c.minute!), UInt8(c.second!), UInt8((c.weekday! - 1) % 7)]
  }

  static func brightness(_ pct: Int) -> [UInt8] { [0x74, UInt8(clamping: max(0, min(100, pct)))] }

  /// Ditoo keyboard backlight: 0 = previous effect, 1 = next effect, 2 = on/off.
  static func keyboardLight(_ action: UInt8) -> [UInt8] { [0x23, action] }
}

/// RFCOMM connection to the Ditoo. Reconnects on its own every 10 s while disconnected.
final class Device: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate {
  enum Status: Equatable {
    case idle, connecting, connected, failed(String)
    var label: String {
      switch self {
      case .idle: return "Not connected"
      case .connecting: return "Connecting…"
      case .connected: return "Connected"
      case .failed(let m): return m
      }
    }
  }

  @Published private(set) var status: Status = .idle
  @Published private(set) var name = ""
  var onConnect: (() -> Void)?
  var onReceive: (([UInt8]) -> Void)?

  private(set) var address = ""
  private var channelID: UInt8 = 1
  private var device: IOBluetoothDevice?
  private var channel: IOBluetoothRFCOMMChannel?
  private var retryTimer: Timer?
  private var generation = 0  // bumps on every new screen; cancels pending animation chunks

  var isConnected: Bool { channel != nil }

  struct Paired: Hashable { let name: String, address: String }

  static func paired() -> [Paired] {
    let all = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return all.map { Paired(name: $0.name ?? "?", address: $0.addressString.uppercased()) }
      .sorted { a, b in
        let da = a.name.lowercased().contains("ditoo"), db = b.name.lowercased().contains("ditoo")
        return da != db ? da : a.name < b.name
      }
  }

  func connect(address: String, channel: Int = 1) {
    disconnect()
    self.address = address.replacingOccurrences(of: ":", with: "-")
    channelID = UInt8(clamping: channel)
    attempt()
  }

  func disconnect() {
    retryTimer?.invalidate(); retryTimer = nil
    stuckTimer?.invalidate(); stuckTimer = nil
    channel?.setDelegate(nil)
    channel?.close()
    channel = nil
    status = .idle
  }

  private func attempt() {
    retryTimer?.invalidate(); retryTimer = nil
    guard !address.isEmpty else { status = .failed("Choose your Ditoo in Settings"); return }
    guard let d = IOBluetoothDevice(addressString: address) else { fail("Invalid address"); return }
    device = d
    name = d.name ?? address
    status = .connecting
    stuckTimer?.invalidate()
    stuckTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.stuck() }
    if d.isConnected() {
      openChannel()
    } else if d.openConnection(self) != kIOReturnSuccess {  // async → connectionComplete
      fail("Ditoo not reachable")
    }
  }

  private var stuckTimer: Timer?
  private var stuckCount = 0
  private var pending: IOBluetoothRFCOMMChannel?  // channel being opened

  /// The Ditoo sometimes never answers an RFCOMM open (e.g. it still holds a channel from a killed
  /// process). Retry, and on the second hang drop the Bluetooth link so it starts fresh.
  private func stuck() {
    guard case .connecting = status else { return }
    stuckCount += 1
    pending?.setDelegate(nil); pending?.close(); pending = nil
    if stuckCount >= 2 { device?.closeConnection(); stuckCount = 0 }
    fail("Connection timed out")
  }

  @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
    status == kIOReturnSuccess ? openChannel() : fail("Ditoo not reachable")
  }

  private func openChannel() {
    guard let d = device else { return }
    var ch: IOBluetoothRFCOMMChannel?
    let r = d.openRFCOMMChannelAsync(&ch, withChannelID: channelID, delegate: self)
    pending = ch
    if r != kIOReturnSuccess { fail("Could not open RFCOMM channel (\(r))") }
  }

  func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
    guard error == kIOReturnSuccess, let ch else { fail("Could not open RFCOMM channel (\(error))"); return }
    channel = ch; pending = nil
    stuckTimer?.invalidate(); stuckCount = 0
    status = .connected
    Log.write("connected to \(name)")
    onConnect?()
  }

  func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
    channel = nil
    fail("Disconnected")
  }

  func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
    guard let data, length > 0 else { return }
    onReceive?(Array(UnsafeRawBufferPointer(start: data, count: length)))
  }

  private func fail(_ msg: String) {
    channel = nil
    status = .failed(msg)
    Log.write("bluetooth: \(msg)")
    retryTimer?.invalidate()
    retryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.attempt() }
  }

  // MARK: sending

  @discardableResult
  func send(_ payload: [UInt8]) -> Bool {
    guard let ch = channel else { return false }
    var pkt = Proto.packet(payload)
    let mtu = max(1, Int(ch.getMTU()))
    var off = 0
    while off < pkt.count {
      let n = min(mtu, pkt.count - off)
      let r = pkt.withUnsafeMutableBytes { ch.writeSync($0.baseAddress! + off, length: UInt16(n)) }
      if r != kIOReturnSuccess { Log.write("write error \(r)"); return false }
      off += n
    }
    return true
  }

  /// Replaces whatever is on screen (cancels a half-sent animation).
  func screen(_ payloads: [UInt8]...) {
    generation += 1
    for p in payloads { send(p) }
  }

  func show(_ a: Animation) {
    generation += 1
    let g = generation
    send(Proto.image(a.frames[0].px))
    guard a.frames.count > 1 else { return }
    // A running animation is only replaced after a still image; then upload the new one.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, self.generation == g else { return }
      for chunk in Proto.animation(a) { self.send(chunk) }
    }
  }
}
