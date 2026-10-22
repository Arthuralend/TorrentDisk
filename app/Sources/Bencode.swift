import CryptoKit
import Foundation

/// Минимальный разбор bencode — ровно столько, сколько нужно, чтобы прочитать .torrent.
enum BValue {
    case int(Int)
    case bytes(Data)
    case list([BValue])
    case dict([String: BValue])

    subscript(key: String) -> BValue? {
        if case .dict(let d) = self { return d[key] }
        return nil
    }

    var string: String? {
        if case .bytes(let b) = self {
            // Старые торренты из Windows иногда хранят имена в CP1251.
            return String(data: b, encoding: .utf8) ?? String(data: b, encoding: .windowsCP1251)
        }
        return nil
    }

    var int: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    var list: [BValue]? {
        if case .list(let l) = self { return l }
        return nil
    }
}

struct BencodeError: LocalizedError {
    var errorDescription: String? { "Файл повреждён или это не .torrent." }
}

private struct BDecoder {
    let bytes: [UInt8]
    var pos = 0
    /// Диапазон байтов словаря info: из него считается infohash.
    var infoRange: Range<Int>?

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func peek() throws -> UInt8 {
        guard pos < bytes.count else { throw BencodeError() }
        return bytes[pos]
    }

    mutating func readNumber(until end: UInt8) throws -> Int {
        let start = pos
        while try peek() != end { pos += 1 }
        guard let s = String(bytes: bytes[start..<pos], encoding: .ascii), let n = Int(s) else {
            throw BencodeError()
        }
        pos += 1
        return n
    }

    mutating func value(depth: Int = 0) throws -> BValue {
        switch try peek() {
        case UInt8(ascii: "i"):
            pos += 1
            return .int(try readNumber(until: UInt8(ascii: "e")))
        case UInt8(ascii: "l"):
            pos += 1
            var items: [BValue] = []
            while try peek() != UInt8(ascii: "e") { items.append(try value(depth: depth + 1)) }
            pos += 1
            return .list(items)
        case UInt8(ascii: "d"):
            pos += 1
            var dict: [String: BValue] = [:]
            while try peek() != UInt8(ascii: "e") {
                guard case .bytes(let k) = try value(depth: depth + 1),
                      let key = String(data: k, encoding: .utf8) else { throw BencodeError() }
                let start = pos
                dict[key] = try value(depth: depth + 1)
                if depth == 0 && key == "info" { infoRange = start..<pos }
            }
            pos += 1
            return .dict(dict)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            let len = try readNumber(until: UInt8(ascii: ":"))
            guard len >= 0, pos + len <= bytes.count else { throw BencodeError() }
            defer { pos += len }
            return .bytes(Data(bytes[pos..<pos + len]))
        default:
            throw BencodeError()
        }
    }
}

struct TorrentMeta {
    let name: String
    let infoHash: String
    let totalSize: Int64

    init(data: Data) throws {
        var decoder = BDecoder(data)
        let root = try decoder.value()
        guard let info = root["info"], let range = decoder.infoRange,
              let name = info["name.utf-8"]?.string ?? info["name"]?.string else {
            throw BencodeError()
        }
        let digest = Insecure.SHA1.hash(data: Data(decoder.bytes[range]))
        self.name = name
        self.infoHash = digest.map { String(format: "%02x", $0) }.joined()
        if let files = info["files"]?.list {
            totalSize = files.reduce(0) { $0 + Int64($1["length"]?.int ?? 0) }
        } else {
            totalSize = Int64(info["length"]?.int ?? 0)
        }
    }
}
