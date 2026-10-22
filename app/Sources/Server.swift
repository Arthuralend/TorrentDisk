import Foundation
import NetFS

struct ServerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Управляет встроенным distribyted и подключением его WebDAV-папок как дисков.
/// Все методы блокирующие — из интерфейса их вызывают в фоне.
final class Server {
    static let port = 36911
    static let route = "torrents"

    let supportDir: URL
    let libraryDir: URL
    private let configURL: URL
    private let logsDir: URL
    private let binaryURL: URL
    private var process: Process?
    private let lock = NSLock()

    init() {
        supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorrentDisk", isDirectory: true)
        libraryDir = supportDir.appendingPathComponent("library", isDirectory: true)
        configURL = supportDir.appendingPathComponent("config.yaml")
        logsDir = supportDir.appendingPathComponent("logs", isDirectory: true)
        binaryURL = supportDir.appendingPathComponent("distribyted")
        for dir in [libraryDir, logsDir, supportDir.appendingPathComponent("metadata")] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Пароль и конфигурация

    /// WebDAV в distribyted слушает все сетевые интерфейсы, поэтому пароль случайный.
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

    private func writeConfig() throws {
        let dir = supportDir.path
        let config = """
        http:
          port: 4444
          ip: "127.0.0.1"
          httpfs: true

        webdav:
          port: \(Server.port)
          user: admin
          pass: "\(password)"

        torrent:
          global_cache_size: 2048
          metadata_folder: "\(dir)/metadata"
          continue_when_add_timeout: true
          add_timeout: 60
          read_timeout: 120

        log:
          path: "\(dir)/logs"
          max_backups: 2
          max_size: 50

        routes:
          - name: \(Server.route)
            torrent_folder: "\(libraryDir.path)"

        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Копирует distribyted из приложения: так он не зависит от того, где лежит приложение,
    /// и не попадает под карантин Gatekeeper.
    private func installBinary() throws {
        guard let bundled = Bundle.main.url(forResource: "distribyted", withExtension: nil) else {
            throw ServerError(message: "В приложении не найден distribyted.")
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

    func start() throws {
        if isRunning { return }
        try installBinary()
        try writeConfig()
        killStray()

        let logURL = logsDir.appendingPathComponent("stdout.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = binaryURL
        p.arguments = ["--config", configURL.path]
        p.currentDirectoryURL = supportDir
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        try p.run()
        lock.lock(); process = p; lock.unlock()

        // Ждём, пока поднимется WebDAV (торренты загружаются до его старта).
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if webdavStatus(path: "/") != nil { return }
            if !p.isRunning {
                throw ServerError(message: "distribyted завершился с ошибкой:\n" + tailLog())
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw ServerError(message: "distribyted не запустился за 3 минуты.\n" + tailLog())
    }

    func stop() {
        lock.lock(); let p = process; process = nil; lock.unlock()
        guard let p, p.isRunning else { return }
        p.interrupt()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    func restart() throws {
        stop()
        try start()
    }

    /// Останавливает distribyted, оставшийся от прошлого запуска.
    private func killStray() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", "distribyted --config \(configURL.path)"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    func tailLog() -> String {
        let url = logsDir.appendingPathComponent("stdout.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        // Убираем цветовые escape-последовательности zerolog.
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        return plain.split(separator: "\n").suffix(8).joined(separator: "\n")
    }

    // MARK: - WebDAV и диски

    func webdavURL(path: String) -> URL {
        var c = URLComponents()
        c.scheme = "http"
        c.host = "127.0.0.1"
        c.port = Server.port
        c.path = path
        return c.url!
    }

    /// Путь торрента внутри WebDAV. Если торрент — одиночный файл (не архив),
    /// подключается общая папка, а файл показывается в ней.
    static func webdavPath(name: String, isFolder: Bool) -> String {
        isFolder ? "/\(route)/\(name)/" : "/\(route)/"
    }

    /// HTTP-код ответа на PROPFIND или nil, если сервер недоступен.
    func webdavStatus(path: String) -> Int? {
        var request = URLRequest(url: webdavURL(path: path), timeoutInterval: 5)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        let auth = Data("admin:\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")

        var status: Int?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            done.signal()
        }.resume()
        done.wait()
        return status
    }

    /// Подключает папку WebDAV как диск и возвращает путь точки монтирования.
    func mount(path: String) throws -> URL {
        guard webdavStatus(path: path) == 207 else {
            throw ServerError(message: "Торрент ещё не загрузился в distribyted. Попробуйте через минуту.")
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
