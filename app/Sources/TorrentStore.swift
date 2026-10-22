import AppKit
import Foundation
import UniformTypeIdentifiers

struct TorrentItem: Codable, Identifiable, Equatable {
    let id: String          // infohash
    var name: String
    var size: Int64
    var addedAt: Date
    var lastUsedAt: Date
}

enum ServerState {
    case stopped, starting, running
}

/// Состояние приложения: история торрентов, подключённые диски, статус движка.
@MainActor
final class TorrentStore: ObservableObject {
    @Published private(set) var items: [TorrentItem] = []
    @Published private(set) var mounts: [String: URL] = [:]
    @Published private(set) var stats: [String: EngineTorrent] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var serverState: ServerState = .stopped
    @Published var errorMessage: String?

    let server = Server()
    private let queue = DispatchQueue(label: "torrentdisk.server")
    private var historyURL: URL { server.supportDir.appendingPathComponent("history.json") }
    private var refreshTimer: Timer?
    private var refreshing = false

    init() {
        loadHistory()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
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
        for url in urls {
            guard url.pathExtension.lowercased() == "torrent" else {
                errorMessage = "«\(url.lastPathComponent)» — не .torrent-файл."
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                let meta = try TorrentMeta(data: data)
                let file = torrentFile(meta.infoHash)
                if !FileManager.default.fileExists(atPath: file.path) {
                    try data.write(to: file, options: .atomic)
                }
                if let i = items.firstIndex(where: { $0.id == meta.infoHash }) {
                    items[i].lastUsedAt = Date()
                } else {
                    items.append(TorrentItem(
                        id: meta.infoHash, name: meta.name, size: meta.totalSize,
                        addedAt: Date(), lastUsedAt: Date()))
                }
                lastAdded = meta.infoHash
            } catch {
                errorMessage = "«\(url.lastPathComponent)»: \(error.localizedDescription)"
            }
        }
        sortItems()
        saveHistory()

        guard let id = lastAdded else { return }
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
        guard items.contains(where: { $0.id == id }) else { return }
        busy.insert(id)
        defer { busy.remove(id) }

        guard await ensureServer() else { return }
        do {
            let server = self.server
            let file = torrentFile(id)
            // Движок сам загружает библиотеку при старте; add для уже добавленного торрента
            // просто вернёт его — так заодно получаем имя папки.
            let torrent = try await run { try server.add(torrentFile: file) }
            stats[id] = torrent
            mounts[id] = try await run { try server.mount(dir: torrent.dir) }
        } catch {
            errorMessage = error.localizedDescription
            return
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
        mounts[id] = nil
    }

    func reveal(_ id: String) {
        guard let mp = mounts[id] else { return }
        NSWorkspace.shared.open(mp)
    }

    func remove(_ id: String) async {
        if mounts[id] != nil { await unmount(id) }
        if server.isRunning {
            let server = self.server
            await perform { server.remove(hash: id) }
        }
        try? FileManager.default.removeItem(at: torrentFile(id))
        items.removeAll { $0.id == id }
        stats[id] = nil
        saveHistory()
        if items.isEmpty {
            await stopAll()
        }
    }

    func stopAll() async {
        for id in Array(mounts.keys) { await unmount(id) }
        let server = self.server
        await perform { server.stop() }
        serverState = .stopped
        stats = [:]
    }

    /// Вызывается при выходе из приложения: отключает диски и останавливает движок.
    func shutdown() {
        for mp in mounts.values { server.unmount(mp) }
        mounts = [:]
        server.stop()
    }

    // MARK: - Движок

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

    /// Обновляет пиры и прогресс; если диск извлекли в Finder, отмечает его как отключённый.
    private func refresh() async {
        if !mounts.isEmpty {
            let mounted = Server.mountedPaths()
            let alive = mounts.filter { mounted.contains($0.value.path) }
            if alive.count != mounts.count { mounts = alive }
        }
        guard serverState == .running, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let server = self.server
        if let list = try? await run({ try server.torrents() }) {
            stats = Dictionary(list.map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a })
        }
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
