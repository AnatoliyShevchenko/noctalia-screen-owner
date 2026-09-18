--!nonstrict
-- Screen Owner — панель привязки устройств к мониторам.
--
-- Панель ничего не решает сама: она спрашивает демон (`screen-owner devices`
-- и `screen-owner monitors`) и правит его конфиг (`screen-owner assign`).
-- Демон замечает изменение файла сам, в течение трёх секунд.
--
-- noctalia не выполняет скриптов при установке плагина — хука post-install у
-- неё нет. Поэтому доустановкой занимается сама панель: при первом открытии
-- она проверяет, чего не хватает, и ставит недостающее одной кнопкой. Демон
-- едет внутри каталога плагина и кладётся из него через readFile/writeFile,
-- пакеты ставятся под командой повышения прав.
--
-- Имена железок демон берёт из sysfs, а он читается без ACL — поэтому в
-- списке видно и то, к чему прав ещё нет.

local TIMEOUT_MS = 4000
local INSTALL_TIMEOUT_MS = 180000 -- ставится пакет, и между делом спрашивают пароль

local DAEMON_SOURCE = "screen-owner.py" -- рядом с этим файлом, внутри плагина
local DAEMON_TARGET = "~/.local/bin/screen-owner"
local AUTOSTART_LINE = 'hl.exec_cmd(bin("screen-owner"))'

local pluginVersion = (function()
    local text = noctalia.readFile("plugin.toml")
    if type(text) ~= "string" then
        return ""
    end
    return ("\n" .. text):match('\nversion%s*=%s*"([^"]+)"') or ""
end)()

local devices = nil -- список железок из `devices`, nil пока не спросили
local monitors = {} -- имена мониторов из `monitors`
local status = nil -- строка ошибки под заголовком
local busy = false
local setup = nil -- { daemon = bool, evdev = bool, running = bool }
local installing = nil -- что ставим прямо сейчас, для подписи на кнопке

local function tr(key, vars)
    return noctalia.tr(key, vars)
end

local function daemonPath()
    local cmd = noctalia.getConfig("command")
    if type(cmd) ~= "string" or cmd == "" then
        cmd = DAEMON_TARGET
    end
    return noctalia.expandPath(cmd)
end

local function privilege()
    local priv = noctalia.getConfig("privilege_command")
    if type(priv) ~= "string" or priv == "" then
        priv = "pkexec"
    end
    local argv = {}
    for word in priv:gmatch("%S+") do
        table.insert(argv, word)
    end
    return argv
end

local function run(argv, timeout, done)
    local ok = noctalia.runAsync(argv, function(result)
        done(result.exitCode == 0 and not result.timedOut, result)
    end, timeout)
    if not ok then
        done(false, { exitCode = -1, stdout = "", stderr = "" })
    end
end

-- Один запуск демона с разбором JSON. Ошибку возвращаем строкой, а не
-- уведомлением: панель открыта, ей есть где показать.
local function ask(args, done)
    local argv = { daemonPath() }
    for _, a in ipairs(args) do
        table.insert(argv, a)
    end
    run(argv, TIMEOUT_MS, function(ok, result)
        if not ok then
            if result.timedOut then
                done(nil, tr("err_timeout"))
            else
                done(nil, (result.stderr ~= "" and result.stderr) or tr("err_failed"))
            end
            return
        end
        local decoded = noctalia.json.decode(result.stdout or "")
        if type(decoded) ~= "table" then
            done(nil, tr("err_bad_json"))
            return
        end
        done(decoded, nil)
    end)
end

local render -- объявлена заранее: на неё ссылаются обработчики ниже

-- Чего не хватает. Три независимые проверки, все дешёвые.
local function checkSetup(done)
    local found = { daemon = false, evdev = false, running = false }
    found.daemon = noctalia.fileExists(daemonPath()) == true
    run({ "python3", "-c", "import evdev" }, TIMEOUT_MS, function(ok)
        found.evdev = ok
        run({ "pgrep", "-f", daemonPath() }, TIMEOUT_MS, function(alive)
            found.running = alive
            setup = found
            done()
        end)
    end)
end

local function refresh()
    if busy then
        return
    end
    busy = true
    checkSetup(function()
        if not (setup.daemon and setup.evdev) then
            busy, devices = false, nil
            render()
            return
        end
        ask({ "devices" }, function(list, err)
            if err then
                busy, status, devices = false, err, nil
                render()
                return
            end
            devices = list
            ask({ "monitors" }, function(data, err2)
                busy = false
                status = err2
                monitors = {}
                if data and type(data.monitors) == "table" then
                    for _, m in ipairs(data.monitors) do
                        table.insert(monitors, m.name)
                    end
                end
                render()
            end)
        end)
    end)
end

-- Следующий монитор по кругу, последним — «не привязан». С двумя мониторами
-- это один клик вместо меню, ради чего всё и затевалось.
local function nextMonitor(current)
    if #monitors == 0 then
        return nil
    end
    if current == nil then
        return monitors[1]
    end
    for i, name in ipairs(monitors) do
        if name == current then
            return monitors[i + 1] -- за последним nil, то есть «не привязан»
        end
    end
    return monitors[1]
end

local function assign(stem, monitor)
    ask({ "assign", stem, monitor or "none" }, function(_, err)
        if err then
            status = err
            render()
        else
            refresh()
        end
    end)
end

local function deviceByStem(stem)
    for _, d in ipairs(devices or {}) do
        if d.stem == stem then
            return d
        end
    end
    return nil
end

local function kindGlyph(kind)
    if kind == "keyboard" then
        return "keyboard"
    elseif kind == "mouse" then
        return "mouse"
    elseif kind == "combo" then
        return "devices"
    end
    return "help"
end

local function deviceRow(d)
    local monitor = d.monitor or tr("unassigned")
    local suffix = d.access and "" or "  " .. tr("no_access")
    return ui.button({
        key = "dev-" .. d.stem .. "-" .. tostring(d.monitor),
        glyph = kindGlyph(d.kind),
        text = d.name .. "   " .. monitor .. suffix,
        variant = d.monitor and "primary" or "ghost",
        contentAlign = "start",
        tooltip = tr("tip_row"),
        onClick = function()
            assign(d.stem, nextMonitor(d.monitor))
        end,
        onRightClick = function()
            local items = { { kind = "header", label = d.name } }
            for _, name in ipairs(monitors) do
                table.insert(items, {
                    id = name,
                    label = tr("menu.assign", { monitor = name }),
                    enabled = d.monitor ~= name,
                })
            end
            table.insert(items, {
                id = "none",
                label = tr("menu.unassign"),
                enabled = d.monitor ~= nil,
            })
            panel.openContextMenu({
                onActivate = "onPickMonitor",
                context = d.stem,
                items = items,
            })
        end,
    })
end

local function needsAccess()
    for _, d in ipairs(devices or {}) do
        if d.monitor and not d.access then
            return true
        end
    end
    return false
end

-- Доустановка. Шаги идут по очереди, каждый следующий — из колбэка предыдущего,
-- чтобы диалог polkit не всплывал дважды одновременно.
local function installDaemon(done)
    local text = noctalia.readFile(DAEMON_SOURCE)
    if type(text) ~= "string" or text == "" then
        done(false, tr("err_no_source"))
        return
    end
    local target = daemonPath()
    noctalia.mkdirAll(target:match("^(.*)/[^/]+$") or target)
    if not noctalia.writeFile(target, text) then
        done(false, tr("err_write", { path = target }))
        return
    end
    run({ "chmod", "+x", target }, TIMEOUT_MS, function(ok)
        done(ok, ok and nil or tr("err_chmod"))
    end)
end

local function installEvdev(done)
    local argv = privilege()
    -- --needed, чтобы повторный запуск ничего не трогал; --noconfirm, потому
    -- что отвечать на вопросы pacman в этом окне негде.
    for _, a in ipairs({ "pacman", "-S", "--needed", "--noconfirm", "python-evdev" }) do
        table.insert(argv, a)
    end
    run(argv, INSTALL_TIMEOUT_MS, function(ok, result)
        done(ok, ok and nil or ((result.stderr ~= "" and result.stderr) or tr("err_pacman")))
    end)
end

local function startDaemon(done)
    -- Запуск без ожидания: демон живёт, пока жив сеанс, поэтому короткий
    -- таймаут тут ничего не значит — важно только, что процесс поднялся.
    noctalia.runAsync({ daemonPath() }, function() end, 1)
    done(true, nil)
end

local function finishInstall(ok, err)
    installing = nil
    busy = false
    if ok then
        noctalia.notify(tr("installed"))
        refresh()
    else
        status = err or tr("err_failed")
        render()
    end
end

function onInstall()
    if busy then
        return
    end
    busy = true
    local steps = {}
    if setup and not setup.evdev then
        table.insert(steps, { name = "evdev", fn = installEvdev })
    end
    if setup and not setup.daemon then
        table.insert(steps, { name = "daemon", fn = installDaemon })
    end
    table.insert(steps, { name = "start", fn = startDaemon })

    local index = 0
    local function next()
        index = index + 1
        local step = steps[index]
        if step == nil then
            finishInstall(true, nil)
            return
        end
        installing = step.name
        render()
        step.fn(function(ok, err)
            if ok then
                next()
            else
                finishInstall(false, err)
            end
        end)
    end
    next()
end

function onGrantAccess()
    if busy then
        return
    end
    local argv = privilege()
    table.insert(argv, daemonPath())
    table.insert(argv, "udev-rule")
    table.insert(argv, "--install")
    busy, installing = true, "access"
    render()
    run(argv, INSTALL_TIMEOUT_MS, function(ok)
        installing = nil
        busy = false
        if ok then
            noctalia.notify(tr("access_granted"))
            refresh()
        else
            status = tr("err_access")
            render()
        end
    end)
end

function onCopyAutostart()
    noctalia.copyToClipboard(AUTOSTART_LINE)
    noctalia.notify(tr("autostart_copied"))
end

function onPickMonitor(action, context)
    local d = deviceByStem(context)
    if d == nil then
        return
    end
    assign(d.stem, action ~= "none" and action or nil)
end

function onRefresh()
    refresh()
end

function onOpenSettings()
    noctalia.openSettings("brick/screen-owner")
end

function onClosePanel()
    panel.close()
end

local function installLabel()
    if installing == "evdev" then
        return tr("installing_evdev")
    elseif installing == "daemon" then
        return tr("installing_daemon")
    elseif installing == "start" then
        return tr("installing_start")
    end
    return tr("install")
end

-- Экран доустановки вместо списка: пока нет демона или python-evdev,
-- спрашивать устройства не у кого.
local function setupSection()
    local missing = {}
    if not setup.evdev then
        table.insert(missing, tr("missing_evdev"))
    end
    if not setup.daemon then
        table.insert(missing, tr("missing_daemon"))
    end
    return {
        ui.label({ key = "setup-why", text = tr("setup_why"), color = "on_surface_variant", maxLines = 3 }),
        ui.label({ key = "setup-list", text = table.concat(missing, "\n"), color = "error", maxLines = 4 }),
        ui.button({
            key = "install" .. (busy and "-off" or ""),
            glyph = "download",
            text = installLabel(),
            variant = "primary",
            enabled = not busy,
            onClick = "onInstall",
        }),
    }
end

render = function()
    local children = {
        ui.row({ key = "head", gap = 8, align = "center" }, {
            ui.label({
                key = "title",
                text = tr("title"),
                fontSize = 14,
                fontWeight = "semibold",
                color = "on_surface",
                flexGrow = 1,
            }),
            ui.label({ key = "version", text = pluginVersion, fontSize = 10, color = "on_surface_variant" }),
            ui.button({
                key = "refresh" .. (busy and "-off" or ""),
                glyph = "refresh",
                variant = "ghost",
                enabled = not busy,
                tooltip = tr("tip_refresh"),
                onClick = "onRefresh",
            }),
            ui.button({ key = "settings", glyph = "settings", variant = "ghost", tooltip = tr("tip_settings"), onClick = "onOpenSettings" }),
            ui.button({ key = "close", glyph = "close", variant = "ghost", tooltip = tr("tip_close"), onClick = "onClosePanel" }),
        }),
    }

    if status then
        table.insert(children, ui.label({ key = "status", text = status, color = "error", maxLines = 3 }))
    end

    if setup ~= nil and not (setup.daemon and setup.evdev) then
        for _, node in ipairs(setupSection()) do
            table.insert(children, node)
        end
    elseif devices == nil then
        table.insert(children, ui.label({ key = "wait", text = tr("loading"), color = "on_surface_variant" }))
    elseif #devices == 0 then
        table.insert(children, ui.label({ key = "empty", text = tr("empty"), color = "on_surface_variant", maxLines = 3 }))
    else
        local rows = {}
        for _, d in ipairs(devices) do
            if d.kind ~= "other" then -- кнопки питания и подсветка корпуса тут не нужны
                table.insert(rows, deviceRow(d))
            end
        end
        table.insert(children, ui.scroll({ key = "list", flexGrow = 1, gap = 4 }, rows))

        if #monitors == 1 then
            table.insert(children, ui.label({
                key = "single",
                text = tr("single_monitor"),
                fontSize = 11,
                color = "on_surface_variant",
                maxLines = 2,
            }))
        end

        if needsAccess() then
            table.insert(children, ui.separator({ key = "sep-access" }))
            table.insert(children, ui.row({ key = "grant-row", gap = 8, align = "center" }, {
                ui.label({ key = "grant-why", text = tr("access_why"), fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 3 }),
                ui.button({
                    key = "grant" .. (busy and "-off" or ""),
                    glyph = "shield",
                    text = installing == "access" and tr("granting") or tr("grant"),
                    variant = "primary",
                    enabled = not busy,
                    onClick = "onGrantAccess",
                }),
            }))
        end

        -- Автозапуск не прописываем сами: hyprland.lua — чужая территория,
        -- строку проще отдать в буфер, чем править конфиг компоновщика.
        if setup ~= nil and not setup.running then
            table.insert(children, ui.separator({ key = "sep-auto" }))
            table.insert(children, ui.row({ key = "auto-row", gap = 8, align = "center" }, {
                ui.label({ key = "auto-why", text = tr("autostart_why"), fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 3 }),
                ui.button({
                    key = "auto-copy",
                    glyph = "copy",
                    text = tr("autostart_copy"),
                    variant = "ghost",
                    onClick = "onCopyAutostart",
                }),
            }))
        end
    end

    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
end

function onOpen(_context)
    refresh()
end

render()
