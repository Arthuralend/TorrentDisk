import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: TorrentStore
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            dropZone
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            Divider()
            history
            if let message = store.errorMessage {
                errorBanner(message)
            }
            Divider()
            cacheBar
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    // MARK: - Заголовок

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Torrent Disk").font(.title2.bold())
                Text("Торренты как диски — скачивается только то, что открываете")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge
        }
        .padding(20)
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch store.serverState {
            case .running: return ("Работает", .green)
            case .starting: return ("Запускается…", .orange)
            case .stopped: return ("Остановлен", .secondary)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .help(store.serverState == .running ? "Торрент-движок запущен" : "")
    }

    // MARK: - Зона перетаскивания

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "arrow.down.doc")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            Text("Перетащите .torrent-файл сюда")
                .font(.headline)
            Button("Выбрать файл…") { store.chooseFiles() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.add(urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    // MARK: - История

    @ViewBuilder
    private var history: some View {
        if store.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Здесь появятся торренты, которые вы открывали")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Недавние торренты").font(.headline)
                    Spacer()
                    if !store.mounts.isEmpty {
                        Button("Отключить все") { Task { await store.stopAll() } }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 6)

                List {
                    ForEach(store.items) { item in
                        TorrentRow(item: item)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Кеш

    private var cacheBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
            Text(cacheText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Скачанные куски хранятся здесь, чтобы не качать их повторно. "
                      + "Когда кеш заполнен, давно не открывавшиеся куски удаляются.")
            if let cache = store.cache, cache.capacity > 0 {
                ProgressView(value: min(Double(cache.used) / Double(cache.capacity), 1))
                    .frame(width: 80)
            }
            Spacer()
            Menu {
                ForEach(TorrentStore.cacheLimitChoices, id: \.self) { gb in
                    Button {
                        Task { await store.setCacheLimit(gb: gb) }
                    } label: {
                        if gb == store.cacheLimitGB {
                            Label("\(gb) ГБ", systemImage: "checkmark")
                        } else {
                            Text("\(gb) ГБ")
                        }
                    }
                }
            } label: {
                Text("Лимит: \(store.cacheLimitGB) ГБ")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button("Очистить кеш") { Task { await store.clearCache() } }
                .disabled(store.serverState != .running || (store.cache?.used ?? 0) == 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var cacheText: String {
        let limit = "\(store.cacheLimitGB) ГБ"
        guard let cache = store.cache else { return "Кеш: лимит \(limit)" }
        let used = ByteCountFormatter.string(fromByteCount: cache.used, countStyle: .file)
        return "Кеш: \(used) из \(limit)"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                store.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}

struct TorrentRow: View {
    @EnvironmentObject var store: TorrentStore
    let item: TorrentItem

    private var isMounted: Bool { store.mounts[item.id] != nil }
    private var isBusy: Bool { store.busy.contains(item.id) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isMounted ? "externaldrive.fill.badge.checkmark" : "externaldrive")
                .font(.title2)
                .foregroundStyle(isMounted ? Color.accentColor : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Торрент передаётся кусками: даже ради одной маленькой книги "
                          + "скачивается как минимум один кусок целиком.")
            }

            Spacer(minLength: 8)

            if isBusy {
                ProgressView().controlSize(.small)
            } else if isMounted {
                Button("Открыть") { store.reveal(item.id) }
                Button("Отключить") { Task { await store.unmount(item.id) } }
            } else {
                Button("Подключить") { Task { await store.mount(item.id) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if isMounted {
                Button("Показать в Finder") { store.reveal(item.id) }
                Button("Отключить") { Task { await store.unmount(item.id) } }
            } else {
                Button("Подключить") { Task { await store.mount(item.id) } }
            }
            Divider()
            Button("Удалить из истории", role: .destructive) { Task { await store.remove(item.id) } }
        }
    }

    private var details: String {
        var parts = [ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)]
        let stat = store.stats[item.id]
        if let piece = item.pieceSize ?? stat?.pieceSize, piece > 0 {
            parts.append("кусок \(ByteCountFormatter.string(fromByteCount: piece, countStyle: .memory))")
        }
        if (isMounted || isBusy), let stat {
            parts.append(stat.peers == 0 ? "ищу пиров…" : "пиров: \(stat.peers)")
            parts.append("скачано \(ByteCountFormatter.string(fromByteCount: stat.completed, countStyle: .file))")
        } else {
            parts.append(item.lastUsedAt.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}
