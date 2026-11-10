import Foundation
import Network

/// Local development port (127.0.0.1:40404), one command per line, e.g. `send 23 01` or `show clock`.
/// Lets protocol experiments and screen changes happen without rebuilding or reconnecting.
/// Bytes the Ditoo sends back are pushed to every open connection as `rx: …`.
final class DevServer {
  static let port: NWEndpoint.Port = 40404
  private var listener: NWListener?
  private var conns: [ObjectIdentifier: NWConnection] = [:]
  private let handle: (String) -> String

  init(handle: @escaping (String) -> String) { self.handle = handle }

  func start() {
    let params = NWParameters.tcp
    params.acceptLocalOnly = true
    guard let l = try? NWListener(using: params, on: DevServer.port) else { Log.write("dev: can't listen"); return }
    l.newConnectionHandler = { [weak self] c in self?.accept(c) }
    l.start(queue: .main)
    listener = l
  }

  func broadcast(_ line: String) { for c in conns.values { reply(c, line) } }

  private func accept(_ c: NWConnection) {
    let id = ObjectIdentifier(c)
    conns[id] = c
    c.stateUpdateHandler = { [weak self] st in
      switch st {
      case .failed, .cancelled: self?.conns[id] = nil
      default: break
      }
    }
    c.start(queue: .main)
    read(c, Data())
  }

  private func read(_ c: NWConnection, _ pending: Data) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
      guard let self else { return }
      var buf = pending + (data ?? Data())
      while let nl = buf.firstIndex(of: 10) {
        let line = String(decoding: buf[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        buf = Data(buf[buf.index(after: nl)...])
        if !line.isEmpty { self.reply(c, self.handle(line)) }
      }
      if done || err != nil { c.cancel(); return }
      self.read(c, buf)
    }
  }

  private func reply(_ c: NWConnection, _ s: String) {
    c.send(content: Data((s + "\n").utf8), completion: .contentProcessed { _ in })
  }
}

enum Hex {
  static func parse(_ s: String) -> [UInt8]? {
    let h = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: "")
    guard h.count % 2 == 0, !h.isEmpty else { return nil }
    var out: [UInt8] = []
    var i = h.startIndex
    while i < h.endIndex {
      let j = h.index(i, offsetBy: 2)
      guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
      out.append(b); i = j
    }
    return out
  }
  static func string(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
}
