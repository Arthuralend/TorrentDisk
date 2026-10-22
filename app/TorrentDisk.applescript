on run
	set r to button returned of (display dialog "Перетащите .torrent-файл на значок Torrent Disk или откройте его через «Открыть в программе», чтобы подключить как диск." buttons {"Папка торрентов", "Остановить", "Открыть диск"} default button "Открыть диск" with title "Torrent Disk")
	if r is "Открыть диск" then
		runHelper("open")
	else if r is "Остановить" then
		runHelper("stop")
	else
		runHelper("folder")
	end if
end run

on open theFiles
	set args to ""
	repeat with f in theFiles
		set p to POSIX path of f
		if p ends with ".torrent" then set args to args & " " & quoted form of p
	end repeat
	if args is "" then
		display alert "Torrent Disk" message "Нужен файл с расширением .torrent."
		return
	end if
	display notification "Подключаю торрент…" with title "Torrent Disk"
	runHelper("add" & args)
end open

on runHelper(cmd)
	try
		do shell script quoted form of (POSIX path of (path to resource "tdisk.sh")) & " " & cmd
	on error errMsg
		display alert "Torrent Disk: ошибка" message errMsg
	end try
end runHelper
