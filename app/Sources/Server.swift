import Foundation
import NetFS

struct ServerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Торрент, как его видит движок.
struct EngineTorrent: Decodable, Equatable {
    let hash: String
    let name: String
    let dir: String
    let size: Int64
    let completed: Int64
    let peers: Int
    let seeders: Int
    let pieceSize: Int64
}

struct CacheStatus: Decodable, Equatable {
    let used: Int64
    let capacity: Int64
}

/// Управляет встроенным движком (torrentdisk-engine) и подключением его WebDAV-папок как дисков.
/// Все методы блокирующие — из интерфейса их вызывают в фоне.
final class Server {
    static let webdavPort = 36911
    static let apiPort = 36912
    static let engineName = "torrentdisk-engine"

    let supportDir: URL
    let libraryDir: URL
    private let logsDir: URL
    private let binaryURL: URL
    private var process: Process?
    private let lock = NSLock()

    init() {
        supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrentDisk", isDirectory: true)
        libraryDir = supportDir.appendingPathComponent("library", isDirectory: true)
        logsDir = supportDir.appendingPathComponent("logs", isDirectory: true)
        binaryURL = supportDir.appendingPathComponent(Server.engineName)
        for dir in [libraryDir, logsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Остатки версии 2.0, работавшей через distribyted.
        for old in ["distribyted", "config.yaml", "metadata"] {
            try? FileManager.default.removeItem(at: supportDir.appendingPathComponent(old))
        }
    }

    /// Пароль WebDAV: случайный, хранится в папке приложения.
    lazy var password: String = {
        let url = supportDir.appendingPathComponent(".password")
        if let saved = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        let pass = (0..<24).map { _ in String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!) }.joined()
        try? pass.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return pass
    }()

    /// Копирует движок из приложения: так он не зависит от того, где лежит приложение,
    /// и не попадает под карантин Gatekeeper.
    private func installBinary() throws {
        guard let bundled = Bundle.main.url(forResource: Server.engineName, withExtension: nil) else {
            throw ServerError(message: "В приложении не найден \(Server.engineName).")
        }
        let fm = FileManager.default
        if fm.contentsEqual(atPath: bundled.path, andPath: binaryURL.path) { return }
        try? fm.removeItem(at: binaryURL)
        try fm.copyItem(at: bundled, to: binaryURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        removexattr(binaryURL.path, "com.apple.quarantine", 0)
    }

    // MARK: - Процесс

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// Лимит кеша скачанных кусков, передаётся движку при запуске.
    var cacheLimit: Int64 = 2 << 30

    func start() throws {
        if isRunning { return }
        try installBinary()
        killStray()

        let logURL = logsDir.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = binaryURL
        p.arguments = [
            "-data", supportDir.path,
            "-webdav", "127.0.0.1:\(Server.webdavPort)",
            "-api", "127.0.0.1:\(Server.apiPort)",
            "-cache-mb", String(cacheLimit >> 20),
        ]
        var env = ProcessInfo.processInfo.environment
        env["TD_PASS"] = password
        p.environment = env
        p.currentDirectoryURL = supportDir
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        try p.run()
        lock.lock(); process = p; lock.unlock()

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if (try? api("GET", "/api/health").0) == 200 { return }
            if !p.isRunning {
                throw ServerError(message: "Движок завершился с ошибкой:\n" + tailLog())
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw ServerError(message: "Движок не запустился.\n" + tailLog())
    }

    func stop() {
        lock.lock(); let p = process; process = nil; lock.unlock()
        guard let p, p.isRunning else { return }
        p.interrupt()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// Останавливает движок, оставшийся от прошлого запуска.
    private func killStray() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "\(Server.engineName) -data \(supportDir.path)"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    func tailLog() -> String {
        let url = logsDir.appendingPathComponent("engine.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(8).joined(separator: "\n")
    }

    // MARK: - API движка

    private func api(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 5) throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Server.apiPort)\(path)")!, timeoutInterval: timeout)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try send(request)
    }

    private func send(_ request: URLRequest) throws -> (Int, Data) {
        var result: Result<(Int, Data), Error> = .failure(ServerError(message: "Нет ответа от движка."))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    func torrents() throws -> [EngineTorrent] {
        let (code, data) = try api("GET", "/api/torrents")
        guard code == 200 else { throw ServerError(message: "Движок ответил \(code).") }
        return try JSONDecoder().decode([EngineTorrent].self, from: data)
    }

    func add(torrentFile: URL) throws -> EngineTorrent {
        let body = try JSONSerialization.data(withJSONObject: ["path": torrentFile.path])
        let (code, data) = try api("POST", "/api/torrents", body: body, timeout: 30)
        guard code == 200 else {
            throw ServerError(message: String(data: data, encoding: .utf8) ?? "Не удалось добавить торрент.")
        }
        return try JSONDecoder().decode(EngineTorrent.self, from: data)
    }

    func remove(hash: String) {
        _ = try? api("DELETE", "/api/torrents/\(hash)")
    }

    func cacheStatus() throws -> CacheStatus {
        let (code, data) = try api("GET", "/api/cache")
        guard code == 200 else { throw ServerError(message: "Движок ответил \(code).") }
        return try JSONDecoder().decode(CacheStatus.self, from: data)
    }

    func clearCache() throws -> CacheStatus {
        let (_, data) = try api("POST", "/api/cache/clear", timeout: 60)
        return try JSONDecoder().decode(CacheStatus.self, from: data)
    }

    func setCacheLimit(_ bytes: Int64) throws -> CacheStatus {
        let body = try JSONSerialization.data(withJSONObject: ["capacity": bytes])
        let (_, data) = try api("POST", "/api/cache/capacity", body: body, timeout: 60)
        return try JSONDecoder().decode(CacheStatus.self, from: data)
    }

    // MARK: - WebDAV и диски

    func webdavURL(path: String) -> URL {
        var c = URLComponents()
        c.scheme = "http"
        c.host = "127.0.0.1"
        c.port = Server.webdavPort
        c.path = path
        return c.url!
    }

    static func webdavPath(dir: String) -> String { "/\(dir)/" }

    /// HTTP-код ответа на PROPFIND или nil, если сервер недоступен.
    func webdavStatus(path: String) -> Int? {
        var request = URLRequest(url: webdavURL(path: path), timeoutInterval: 10)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        let auth = Data("admin:\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        return try? send(request).0
    }

    /// Подключает папку торрента как диск и возвращает путь точки монтирования.
    func mount(dir: String) throws -> URL {
        let path = Server.webdavPath(dir: dir)
        guard webdavStatus(path: path) == 207 else {
            throw ServerError(message: "Движок не видит папку «\(dir)». Подробности в журнале:\n" + tailLog())
        }
        // kNAUIOptionKey = kNAUIOptionNoUI: не показывать системных окон входа.
        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = "NoUI"
        var mountpoints: Unmanaged<CFArray>?
        let rc = NetFSMountURLSync(
            webdavURL(path: path) as CFURL, nil,
            "admin" as CFString, password as CFString,
            openOptions as CFMutableDictionary, nil, &mountpoints)
        let points = mountpoints.map { $0.takeRetainedValue() as NSArray as? [String] ?? [] } ?? []
        guard rc == 0, let first = points.first else {
            throw ServerError(message: "Не удалось подключить диск (код \(rc)).")
        }
        return URL(fileURLWithPath: first, isDirectory: true)
    }

    func unmount(_ mountPoint: URL) {
        let umount = Process()
        umount.executableURL = URL(fileURLWithPath: "/sbin/umount")
        umount.arguments = [mountPoint.path]
        try? umount.run()
        umount.waitUntilExit()
        if umount.terminationStatus != 0 {
            let force = Process()
            force.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            force.arguments = ["unmount", "force", mountPoint.path]
            try? force.run()
            force.waitUntilExit()
        }
    }

    /// Точки монтирования, которые сейчас есть в системе.
    static func mountedPaths() -> Set<String> {
        var buf: UnsafeMutablePointer<statfs>?
        let n = getmntinfo(&buf, MNT_NOWAIT)
        guard n > 0, let buf else { return [] }
        var result = Set<String>()
        for i in 0..<Int(n) {
            var fs = buf[i]
            let path = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            result.insert(path)
        }
        return result
    }
}
