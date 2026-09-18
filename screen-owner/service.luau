--!nonstrict
-- Фоновая часть плагина: поднимает демон при старте noctalia, если это
-- разрешено настройкой. Заменяет собой строчку в hyprland.lua — конфиг
-- компоновщика трогать не приходится вовсе.
--
-- Запуск через `setsid -f`: процесс отвязывается сразу, поэтому ни таймаут
-- runAsync, ни перезагрузка плагина его не убивают. Умирает он сам, когда
-- Hyprland закрывает свой сокет, то есть вместе с сеансом.

local function daemonPath()
    local cmd = noctalia.getConfig("command")
    if type(cmd) ~= "string" or cmd == "" then
        cmd = "~/.local/bin/screen-owner"
    end
    return noctalia.expandPath(cmd)
end

local function start()
    local path = daemonPath()
    if not noctalia.fileExists(path) then
        return -- ещё не установлен: этим займётся панель
    end
    -- Второй экземпляр не нужен: перехват устройства держит только один
    -- процесс, второй получил бы EBUSY и работал бы вполсилы.
    noctalia.runAsync({ "pgrep", "-f", path }, function(result)
        if result.exitCode == 0 then
            return
        end
        noctalia.runAsync({ "setsid", "-f", path }, function() end, 2000)
        noctalia.log("screen-owner: демон запущен")
    end, 3000)
end

if noctalia.getConfig("autostart") ~= false then
    start()
end
