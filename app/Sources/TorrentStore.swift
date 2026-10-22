import AppKit
import Foundation
import UniformTypeIdentifiers

struct TorrentItem: Codable, Identifiable, Equatable {
    let id: String          // infohash
    var name: String
    var size: Int64
    var isFolder: Bool
    var addedAt: Date
    var lastUsedAt: Date

    var webdavPath: String { Server.webdavPath(name: name, isFolder: isFolder) }
}

enum ServerState {
    case stopped, starting, running
}

/// Состояние приложения: история торрентов, подключённые диски, статус сервера.
@MainActor
final class TorrentStore: ObservableObject {
    @Published private(set) var items: [TorrentItem] = []
    @Published private(set) var mounts: [String: URL] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var serverState: ServerState = .stopped
    @Published var errorMessage: String?

    let server = Server()
    private let queue = DispatchQueue(label: "torrentdisk.server")
    private var historyURL: URL { server.supportDir.appendingPathComponent("history.json") }
    private var refreshTimer: Timer?

    init() {
        loadHistory()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.dropEjectedMounts() }
        }
        if !items.isEmpty {
            Task { await ensureServer() }
        }
    }

    // MARK: - История

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([TorrentItem].self, from: data)) ?? []
        // Если файл торрента пропал из библиотеки, убираем и запись.
        items.removeAll { !FileManager.default.fileExists(atPath: torrentFile($0.id).path) }
        sortItems()
    }

    private func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(items).write(to: historyURL, options: .atomic)
    }

    private func sortItems() {
        items.sort { $0.lastUsedAt > $1.lastUsedAt }
    }

    private func torrentFile(_ id: String) -> URL {
        server.libraryDir.appendingPathComponent("\(id).torrent")
    }

    private func touch(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastUsedAt = Date()
        sortItems()
        saveHistory()
    }

    // MARK: - Действия

    /// Добавляет .torrent-файлы в историю и сразу подключает последний из них.
    func add(_ urls: [URL]) async {
        var lastAdded: String?
        var hasNew = false
        for url in urls {
            guard url.pathExtension.lowercased() == "torrent" else {
                errorMessage = "«\(url.lastPathComponent)» — не .torrent-файл."
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                let meta = try TorrentMeta(data: data)
                if let i = items.firstIndex(where: { $0.id == meta.infoHash }) {
                    items[i].lastUsedAt = Date()
                } else {
                    try data.write(to: torrentFile(meta.infoHash), options: .atomic)
                    items.append(TorrentItem(
                        id: meta.infoHash, name: meta.name, size: meta.totalSize,
                        isFolder: meta.isFolder, addedAt: Date(), lastUsedAt: Date()))
                    hasNew = true
                }
                lastAdded = meta.infoHash
            } catch {
                errorMessage = "«\(url.lastPathComponent)»: \(error.localizedDescription)"
            }
        }
        sortItems()
        saveHistory()

        guard let id = lastAdded else { return }
        // distribyted читает папку с торрентами только при старте.
        if hasNew {
            await restartServer()
        }
        if mounts[id] == nil {
            await mount(id)
        } else {
            reveal(id)
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.message = "Выберите .torrent-файлы"
        if panel.runModal() == .OK {
            Task { await add(panel.urls) }
        }
    }

    func mount(_ id: String, open: Bool = true) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        busy.insert(id)
        defer { busy.remove(id) }

        guard await ensureServer() else { return }

        // Одиночные файлы (не архивы) лежат в общей папке — её можно подключить только один раз.
        let shared = items.first { $0.id != id && $0.webdavPath == item.webdavPath && mounts[$0.id] != nil }
        if let shared, let mp = mounts[shared.id] {
            mounts[id] = mp
        } else {
            do {
                let path = item.webdavPath
                let server = self.server
                mounts[id] = try await run { try server.mount(path: path) }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        touch(id)
        if open { reveal(id) }
    }

    func unmount(_ id: String) async {
        guard let mp = mounts[id] else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        let server = self.server
        await perform { server.unmount(mp) }
        mounts = mounts.filter { $0.value != mp }
    }

    func reveal(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), let mp = mounts[id] else { return }
        if item.isFolder {
            NSWorkspace.shared.open(mp)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([mp.appendingPathComponent(item.name)])
        }
    }

    func remove(_ id: String) async {
        if mounts[id] != nil { await unmount(id) }
        try? FileManager.default.removeItem(at: torrentFile(id))
        items.removeAll { $0.id == id }
        saveHistory()
        if items.isEmpty {
            await stopAll()
        } else if serverState == .running {
            await restartServer()
        }
    }

    func stopAll() async {
        for id in Array(mounts.keys) { await unmount(id) }
        let server = self.server
        await perform { server.stop() }
        serverState = .stopped
    }

    /// Вызывается при выходе из приложения: отключает диски и останавливает distribyted.
    func shutdown() {
        for mp in Set(mounts.values) { server.unmount(mp) }
        mounts = [:]
        server.stop()
    }

    // MARK: - Сервер

    @discardableResult
    private func ensureServer() async -> Bool {
        if server.isRunning {
            serverState = .running
            return true
        }
        serverState = .starting
        do {
            let server = self.server
            try await run { try server.start() }
            serverState = .running
            return true
        } catch {
            serverState = .stopped
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Перезапускает distribyted и заново подключает диски, которые были подключены.
    private func restartServer() async {
        let wasMounted = Array(mounts.keys)
        for mp in Set(mounts.values) {
            let server = self.server
            await perform { server.unmount(mp) }
        }
        mounts = [:]
        let server = self.server
        await perform { server.stop() }
        serverState = .stopped
        guard await ensureServer() else { return }
        for id in wasMounted where items.contains(where: { $0.id == id }) {
            await mount(id, open: false)
        }
    }

    /// Если диск извлекли в Finder, отмечаем его как отключённый.
    private func dropEjectedMounts() {
        guard !mounts.isEmpty else { return }
        let mounted = Server.mountedPaths()
        let alive = mounts.filter { mounted.contains($0.value.path) }
        if alive.count != mounts.count { mounts = alive }
    }

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func perform(_ body: @escaping () -> Void) async {
        await withCheckedContinuation { cont in
            queue.async {
                body()
                cont.resume()
            }
        }
    }
}
