import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            exit(SelfTest.run(torrentPath: args[i + 1], mount: args.contains("--mount")))
        }
        TorrentDiskApp.main()
    }
}

struct TorrentDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Torrent Disk", id: "main") {
            ContentView()
                .environmentObject(appDelegate.store)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть .torrent…") { appDelegate.store.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = TorrentStore()

    /// .torrent, открытый через Finder («Открыть в программе») или брошенный на значок в Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { await store.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.shutdown()
    }
}

/// Проверка без интерфейса для CI: запускает distribyted с одним торрентом
/// и убеждается, что его папка доступна по WebDAV (и, с --mount, подключается как диск).
enum SelfTest {
    static func run(torrentPath: String, mount: Bool) -> Int32 {
        let server = Server()
        defer { server.stop() }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: torrentPath))
            let meta = try TorrentMeta(data: data)
            print("torrent: \(meta.name), \(meta.totalSize) bytes, folder=\(meta.isFolder), hash=\(meta.infoHash)")
            try data.write(to: server.libraryDir.appendingPathComponent("\(meta.infoHash).torrent"))

            try server.start()
            let path = Server.webdavPath(name: meta.name, isFolder: meta.isFolder)
            let status = server.webdavStatus(path: path)
            print("PROPFIND \(path): \(status.map(String.init) ?? "no response")")
            guard status == 207 else { return 1 }

            if mount {
                let mp = try server.mount(path: path)
                let files = try FileManager.default.contentsOfDirectory(atPath: mp.path)
                print("mounted at \(mp.path): \(files)")
                server.unmount(mp)
            }
            print("selftest ok")
            return 0
        } catch {
            print("selftest failed: \(error.localizedDescription)")
            print(server.tailLog())
            return 1
        }
    }
}
