# Torrent Disk для macOS

Открывает торрент как диск в Finder, не скачивая его целиком. Перетащите `.torrent`-файл на значок
**Torrent Disk**, и содержимое раздачи появится как сетевой диск. ZIP-, RAR- и 7z-архивы внутри
показываются как обычные папки: если открыть одну книгу из архива на несколько гигабайт, скачаются
только нужные ей куски.

Внутри работает [distribyted](https://github.com/distribyted/distribyted): он подключает торренты
через WebDAV, поэтому расширение ядра macFUSE включать не нужно.

## Установка

Требуется Mac на Apple Silicon (M1 и новее).

1. Скачайте **TorrentDisk.dmg** со страницы [Releases](https://github.com/Arthuralend/TorrentDisk/releases/latest).
2. Откройте его и перетащите **Torrent Disk** в папку «Программы».
3. При первом запуске macOS сообщит, что не может проверить разработчика: у приложения нет платной
   подписи Apple. Откройте «Системные настройки → Конфиденциальность и безопасность» и нажмите
   «Всё равно открыть». Это нужно сделать только один раз.

   Можно и через Терминал: `xattr -dr com.apple.quarantine "/Applications/Torrent Disk.app"`.

## Использование

- **Добавить торрент:** перетащите `.torrent` на значок Torrent Disk или выберите «Открыть в программе → Torrent Disk».
- **Открыть диск, остановить программу или открыть папку торрентов:** запустите Torrent Disk и выберите кнопку в окне.
- **Убрать торрент:** удалите его файл из папки торрентов (`~/Library/Application Support/TorrentDisk/torrents`).
- **Посмотреть статус и добавить magnet-ссылку:** откройте веб-интерфейс http://localhost:4444, пока программа запущена.

Скачанные куски хранятся в `~/Library/Application Support/TorrentDisk`, их объём ограничен 2 ГБ.

## Ограничения

- Лучше всего подходят ZIP-архивы и RAR-архивы без solid-сжатия: в них каждый файл сжат отдельно.
  Из 7z и solid RAR для одного файла часто приходится скачивать большую часть архива.
- Finder заранее читает файлы, чтобы строить превью. Если он начинает качать лишнее, используйте
  для этого диска ForkLift или Cyberduck.
- Новый торрент подключается перезапуском distribyted, поэтому диск на пару секунд отключается.

## Сборка

DMG собирает GitHub Actions (`.github/workflows/build.yml`) на macOS. Сборка из ветки `main`
доступна в артефактах запуска, а при пуше тега `v*` DMG публикуется в Releases. Локально на Mac:
`bash build.sh`, результат появится в `build/TorrentDisk.dmg`.

## Удаление

```bash
"/Applications/Torrent Disk.app/Contents/Resources/tdisk.sh" stop
rm -rf "/Applications/Torrent Disk.app" ~/Library/Application\ Support/TorrentDisk
```

## Лицензии

В приложение встроен distribyted (GPL-3.0). Его лицензия и ссылка на исходный код лежат
в `Torrent Disk.app/Contents/Resources`.
