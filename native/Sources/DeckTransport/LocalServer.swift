import Darwin
import DeckCore
import Foundation

public struct LocalRequest {
  public var method: String
  public var path: String
  public var headers: [String: String]
  public var body: Data
  public var isUnix: Bool
  public var fd: Int32
  public var json: [String: Any] {
    (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
  }
}
public struct LocalResponse {
  public var status: Int
  public var body: Data
  public var contentType: String
  public init(status: Int = 200, body: Data, contentType: String = "application/json") {
    self.status = status
    self.body = body
    self.contentType = contentType
  }
  public static func json<T: Encodable>(_ value: T, status: Int = 200) -> Self {
    .init(status: status, body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
  }
}
public enum LocalIO {
  @discardableResult public static func write(_ data: Data, fd: Int32) -> Bool {
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return true }
      var offset = 0
      while offset < data.count {
        let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
        if count <= 0 { return false }
        offset += count
      }
      return true
    }
  }
  public static func disconnected(_ fd: Int32) -> Bool {
    var byte: UInt8 = 0
    let result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    return result == 0 || (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
  }
  public static func unixAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
      throw CocoaError(.fileWriteInvalidFileName)
    }
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }
  public static func unixRequest(path: String, route: String, body: Data, timeout: Int = 3) throws
    -> Data
  {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
    defer { close(fd) }
    var noSig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout.size(ofValue: noSig)))
    var deadline = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(
      fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout.size(ofValue: deadline)))
    var address = try unixAddress(path)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw CocoaError(.fileReadNoSuchFile) }
    let header = Data(
      "POST \(route) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        .utf8)
    guard write(header + body, fd: fd) else { throw CocoaError(.fileWriteUnknown) }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 { throw CocoaError(.fileReadUnknown) }
      received.append(buffer, count: count)
      if received.count > 524288 { throw CocoaError(.fileReadTooLarge) }
    }
    guard let split = received.range(of: Data("\r\n\r\n".utf8)) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return received.subdata(in: split.upperBound..<received.endIndex)
  }
}
public final class LocalServer: @unchecked Sendable {
  public typealias Handler = @Sendable (LocalRequest) async -> LocalResponse?
  private var sockets: [Int32] = []
  public init() {}
  public func listen(port: UInt16, unixPath: String, handler: @escaping Handler) throws {
    signal(SIGPIPE, SIG_IGN)
    let tcp = socket(AF_INET, SOCK_STREAM, 0)
    var reuse: Int32 = 1
    setsockopt(tcp, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      close(tcp)
      throw NSError(
        domain: "DeckTransport", code: Int(errno),
        userInfo: [
          NSLocalizedDescriptionKey:
            "Port \(port) is already in use. Keep the existing deck running or select a different port."
        ])
    }
    sockets.append(tcp)
    let unix = socket(AF_UNIX, SOCK_STREAM, 0)
    // Runtime directory is private to this user; only an obsolete socket is replaced.
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: unixPath).deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if let attrs = try? FileManager.default.attributesOfItem(atPath: unixPath) {
      guard attrs[.type] as? FileAttributeType == .typeSocket else {
        throw CocoaError(.fileWriteFileExists)
      }
      unlink(unixPath)
    }
    var unixAddress = try LocalIO.unixAddress(unixPath)
    let unixResult = withUnsafePointer(to: &unixAddress) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(unix, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard unixResult == 0 else {
      close(unix)
      throw CocoaError(.fileWriteUnknown)
    }
    chmod(unixPath, 0o600)
    sockets.append(unix)
    for (fd, isUnix) in [(tcp, false), (unix, true)] {
      guard Darwin.listen(fd, 32) == 0 else { throw CocoaError(.fileReadUnknown) }
      DispatchQueue.global(qos: .utility).async {
        while true {
          let client = accept(fd, nil, nil)
          if client < 0 { break }
          var noSig: Int32 = 1
          setsockopt(
            client, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout.size(ofValue: noSig)))
          DispatchQueue.global(qos: .utility).async {
            guard let request = Self.readRequest(client, isUnix: isUnix) else {
              close(client)
              return
            }
            Task {
              defer { close(client) }
              if let response = await handler(request) {
                let reason = response.status == 200 ? "OK" : "Error"
                let headers =
                  "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
                LocalIO.write(Data(headers.utf8) + response.body, fd: client)
              }
            }
          }
        }
      }
    }
  }
  private static func readRequest(_ fd: Int32, isUnix: Bool) -> LocalRequest? {
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(
      fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(
      fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    var headerEnd: Range<Data.Index>?
    while data.count < 32768 {
      let count = read(fd, &buffer, buffer.count)
      guard count > 0 else { return nil }
      data.append(buffer, count: count)
      if let range = data.range(of: Data("\r\n\r\n".utf8)) {
        headerEnd = range
        break
      }
    }
    guard let end = headerEnd, let header = String(data: data[..<end.lowerBound], encoding: .utf8)
    else { return nil }
    let lines = header.components(separatedBy: "\r\n")
    let first = lines[0].split(separator: " ")
    guard first.count == 3 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].lowercased()
      guard headers[name] == nil else { return nil }
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    guard headers["transfer-encoding"] == nil else { return nil }
    let length = Int(headers["content-length"] ?? "0") ?? -1
    guard (0...524288).contains(length) else { return nil }
    var body = Data(data[end.upperBound...])
    while body.count < length {
      let count = read(fd, &buffer, min(buffer.count, length - body.count))
      guard count > 0 else { return nil }
      body.append(buffer, count: count)
    }
    return LocalRequest(
      method: String(first[0]), path: String(first[1]), headers: headers,
      body: Data(body.prefix(length)), isUnix: isUnix, fd: fd)
  }
}
