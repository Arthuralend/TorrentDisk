# Torrent Disk для macOS

Открывает торрент как диск в Finder, не скачивая его целиком. Перетащите `.torrent`-файл на значок
**Torrent Disk**, и содержимое раздачи появится как сетевой диск. ZIP-, RAR- и 7z-архивы внутри
показываются как обычные папки: если открыть одну книгу из архива на несколько гигабайт, скачаются
только нужные ей куски.

Внутри работает [distribyted](https://github.com/distribyted/distribyted): он подключает торренты
через WebDAV, поэтому расширение ядра macFUSE включать не нужно.

## Установка

Требуется Mac на Apple Silicon (M1 и новее). В Терминале выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/Arthuralend/TorrentDisk/main/install-torrent-disk.sh | bash
```

Или скачайте `install-torrent-disk.sh` и запустите `bash install-torrent-disk.sh`.

Установщик:
- скачает distribyted (или возьмёт файл `distribyted-*-darwin-*` из «Загрузок»);
- создаст папку `~/TorrentDisk` с настройками и случайным паролем для WebDAV;
- соберёт приложение `~/Applications/Torrent Disk.app`.

Если distribyted не запускается и пишет про `libfuse`, установите [macFUSE](https://macfuse.github.io).

## Использование

- **Добавить торрент:** перетащите `.torrent` на значок Torrent Disk или выберите «Открыть в программе → Torrent Disk».
- **Открыть диск или остановить программу:** запустите Torrent Disk и выберите нужную кнопку в окне.
- **Убрать торрент:** удалите его файл из `~/TorrentDisk/torrents`.
- **Посмотреть статус и добавить magnet-ссылку:** откройте веб-интерфейс http://localhost:4444, пока программа запущена.

Скачанные куски хранятся в `~/TorrentDisk/data`, их объём ограничен 2 ГБ (`global_cache_size` в
`~/TorrentDisk/config.yaml`). Логи лежат в `~/TorrentDisk/data/logs`.

## Ограничения

- Лучше всего подходят ZIP-архивы и RAR-архивы без solid-сжатия: в них каждый файл сжат отдельно.
  Из 7z и solid RAR для одного файла часто приходится скачивать большую часть архива.
- Finder заранее читает файлы, чтобы строить превью. Если он начинает качать лишнее, используйте
  для этого диска ForkLift или Cyberduck.
- Новый торрент подключается перезапуском distribyted, поэтому диск на пару секунд отключается.

## Удаление

```bash
~/TorrentDisk/tdisk.sh stop
rm -rf ~/TorrentDisk "$HOME/Applications/Torrent Disk.app"
```
