--!nonstrict
-- Screen Owner — панель привязки устройств к мониторам.
--
-- Панель ничего не решает сама: она спрашивает демон (`screen-owner devices`
-- и `screen-owner monitors`) и правит его конфиг (`screen-owner assign`).
-- Демон замечает изменение файла сам, в течение трёх секунд.
--
-- Имена железок демон берёт из sysfs, а он читается без ACL — поэтому в
-- списке видно и то, к чему прав ещё нет. Такая строка честно помечается,
-- и внизу появляется кнопка «Выдать доступ».

local REFRESH_TIMEOUT_MS = 4000

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

local function tr(key, vars)
    return noctalia.tr(key, vars)
end

local function command()
    local cmd = noctalia.getConfig("command")
    if type(cmd) ~= "string" or cmd == "" then
        cmd = "~/.local/bin/screen-owner"
    end
    return noctalia.expandPath(cmd)
end

-- Один запуск демона с разбором JSON. Ошибку возвращаем строкой, а не
-- уведомлением: панель открыта, ей есть где показать.
local function ask(args, done)
    local argv = { command() }
    for _, a in ipairs(args) do
        table.insert(argv, a)
    end
    local ok = noctalia.runAsync(argv, function(result)
        if result.timedOut then
            done(nil, tr("err_timeout"))
            return
        end
        if result.exitCode ~= 0 then
            done(nil, (result.stderr ~= "" and result.stderr) or tr("err_failed"))
            return
        end
        local decoded = noctalia.json.decode(result.stdout or "")
        if type(decoded) ~= "table" then
            done(nil, tr("err_bad_json"))
            return
        end
        done(decoded, nil)
    end, REFRESH_TIMEOUT_MS)
    if not ok then
        done(nil, tr("err_spawn", { cmd = command() }))
    end
end

local render -- объявлена заранее: на неё ссылаются обработчики ниже

local function refresh()
    if busy then
        return
    end
    busy = true
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

-- Правило udev нужно переписывать после каждой новой железки: в него идут
-- VID:PID только назначенных. Кнопка показывается, когда права где-то не выданы.
local function needsAccess()
    for _, d in ipairs(devices or {}) do
        if d.monitor and not d.access then
            return true
        end
    end
    return false
end

function onGrantAccess()
    local priv = noctalia.getConfig("privilege_command")
    if type(priv) ~= "string" or priv == "" then
        priv = "pkexec"
    end
    local argv = {}
    for word in priv:gmatch("%S+") do
        table.insert(argv, word)
    end
    table.insert(argv, command())
    table.insert(argv, "udev-rule")
    table.insert(argv, "--install")
    busy = true
    render()
    -- Таймаут щедрый: между запуском и записью правила стоит диалог polkit,
    -- и пароль надо успеть ввести.
    local ok = noctalia.runAsync(argv, function(result)
        busy = false
        if result.exitCode == 0 then
            noctalia.notify(tr("access_granted"))
            refresh()
        else
            status = tr("err_access")
            render()
        end
    end, 60000)
    if not ok then
        busy, status = false, tr("err_spawn", { cmd = priv })
        render()
    end
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

    if devices == nil then
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
    end

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
        table.insert(children, ui.separator({ key = "sep" }))
        table.insert(children, ui.row({ key = "grant-row", gap = 8, align = "center" }, {
            ui.label({ key = "grant-why", text = tr("access_why"), fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 3 }),
            ui.button({
                key = "grant",
                glyph = "shield",
                text = tr("grant"),
                variant = "primary",
                enabled = not busy,
                onClick = "onGrantAccess",
            }),
        }))
    end

    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
end

function onOpen(_context)
    refresh()
end

render()
