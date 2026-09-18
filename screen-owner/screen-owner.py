#!/usr/bin/env python3
"""Комплект клавиатура+мышь владеет своим монитором.

Тронул набор — курсор уезжает на его монитор, фокус идёт за курсором
(при follow_mouse = 1). Монитора нет в системе — набор работает как
обычный и ничего не переключает.

Клавиатуры из GRAB перехватываются целиком и отдаются Hyprland через копию
на uinput: только так можно переключить экран ДО того, как нажатие дойдёт
до окна. Иначе первая буква улетает в прежнее окно.

Открываются только устройства из SETS: геймпад и виртуальные устройства
input-remapper демон не видит в принципе.

  SO_DEBUG=1   подробный лог решений
  SO_NOGRAB=1  не перехватывать клавиатуры (аварийный режим)
"""
import json, os, re, signal, socket, selectors, sys, time
from evdev import InputDevice, UInput, ecodes

CONFIG = os.path.expanduser("~/.config/screen-owner/config.json")

# Значения по умолчанию: ими заполняется config.json при первом запуске.
# Дальше правит его панель noctalia, а здесь остаётся только запасной вариант.
# Пусто намеренно: на чужой машине железки другие, и подсунутые чужие имена
# дали бы в config.json мусор из несуществующих устройств. Первый запуск даёт
# пустую карту, дальше её заполняет панель noctalia.
DEFAULT_SETS = {}
DEFAULT_GRAB = []


def load_config():
    """(карта префикс→монитор, множество нод под перехват). Файла нет — создаём."""
    try:
        with open(CONFIG) as f:
            data = json.load(f)
        return dict(data.get("map", {})), set(data.get("grab", []))
    except FileNotFoundError:
        save_config(DEFAULT_SETS, DEFAULT_GRAB)
        return dict(DEFAULT_SETS), set(DEFAULT_GRAB)
    except (ValueError, OSError) as e:
        print(f"конфиг битый ({e}), беру значения по умолчанию")
        return dict(DEFAULT_SETS), set(DEFAULT_GRAB)


def save_config(mapping, grab):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    tmp = CONFIG + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"map": dict(mapping), "grab": sorted(grab)}, f,
                  indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, CONFIG)  # атомарно, чтобы демон не прочитал полфайла


def config_mtime():
    try:
        return os.stat(CONFIG).st_mtime
    except OSError:
        return 0

BYID    = "/dev/input/by-id"
INTENT  = {ecodes.EV_KEY, ecodes.EV_REL, ecodes.EV_ABS}  # что считаем за "я тут"
RESCAN  = 3    # сек, как часто искать переподключённые железки
TIMEOUT = 0.3  # сек, дольше этого Hyprland не ждём — нажатие важнее
DEBUG   = bool(os.environ.get("SO_DEBUG"))
NOGRAB  = bool(os.environ.get("SO_NOGRAB"))


def hypr_dir():
    base = os.environ["XDG_RUNTIME_DIR"] + "/hypr"
    his  = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if his and os.path.isdir(f"{base}/{his}"):
        return f"{base}/{his}"
    return max((f"{base}/{d}" for d in os.listdir(base)), key=os.path.getmtime)


DIR = hypr_dir()


def hypr(cmd):
    """Команды идут в сокет как Lua: dispatch hl.dsp.<что-то>{...}, а не строкой."""
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(TIMEOUT)  # пересылка клавиш не должна ждать композитор
            s.connect(DIR + "/.socket.sock")
            s.sendall(cmd.encode())
            reply = s.recv(1 << 16).decode()
    except OSError as e:
        print(f"сокет молчит ({e}): {cmd}")
        return ""
    if reply.startswith("error"):  # молчать про это нельзя, один раз уже обожглись
        print(f"Hyprland отверг: {cmd}\n  {reply.splitlines()[0]}")
    return reply


def monitors():
    """(подключённые мониторы -> их центр, какой сейчас в фокусе)"""
    ms = json.loads(hypr("j/monitors"))
    centers = {}
    for m in ms:
        w, h = m["width"] / m["scale"], m["height"] / m["scale"]
        if m["transform"] % 2:  # 90/270 градусов — стороны меняются местами
            w, h = h, w
        centers[m["name"]] = (round(m["x"] + w / 2), round(m["y"] + h / 2))
    return centers, next((m["name"] for m in ms if m["focused"]), None)


def cursorpos():
    try:
        c = json.loads(hypr("j/cursorpos"))
        return c["x"], c["y"]
    except (ValueError, KeyError):
        return None


SETS, GRAB = {}, set()  # заполняются из конфига при старте

# "usb-SEMICO_USB_Gaming_Keyboard-if01-event-kbd" -> "usb-SEMICO_USB_Gaming_Keyboard":
# у одной железки несколько нод, а привязка к монитору у неё одна.
STEM = re.compile(r"-(if\d+-)?(event|mouse|js)\d*(-\w+)?$")


def stem(name):
    return STEM.sub("", name)


def owner(name):
    for prefix, mon in SETS.items():
        if name.startswith(prefix):
            return mon


def sysfs(node, *parts):
    try:
        with open(os.path.join("/sys/class/input", node, "device", *parts)) as f:
            return f.read().strip()
    except OSError:
        return ""


def capmask(node, what):
    """Маска возможностей из sysfs: слова по 64 бита, младшее — последнее."""
    words = sysfs(node, "capabilities", what).split()
    value = 0
    for i, w in enumerate(reversed(words)):
        try:
            value |= int(w, 16) << (64 * i)
        except ValueError:
            return 0
    return value


def kind_of(node):
    """Клавиатура — та, у которой есть буквы. По одному лишь EV_KEY судить
    нельзя: кнопки есть и у мыши, а медиа-нода клавиатуры умеет EV_REL
    и выдаёт себя за мышь."""
    keys = capmask(node, "key")
    if keys >> ecodes.KEY_A & 1 and keys >> ecodes.KEY_Z & 1:
        return "keyboard"
    if capmask(node, "ev") >> ecodes.EV_REL & 1:
        return "mouse"
    if keys >> ecodes.BTN_LEFT & 1:
        return "mouse"
    return "other"


def inventory():
    """Все устройства ввода, сгруппированные по железкам.

    Имя и VID:PID берутся из sysfs — он читается без ACL, поэтому в списке
    видно и то, к чему доступа ещё нет. Это и нужно панели: показать железку
    и честно сказать, что права не выданы."""
    devices = {}
    try:
        names = os.listdir(BYID)
    except OSError:
        return []
    for name in sorted(names):
        if "event" not in name:
            continue
        path = f"{BYID}/{name}"
        node = os.path.basename(os.path.realpath(path))
        if not node.startswith("event"):
            continue
        key = stem(name)
        d = devices.setdefault(key, {
            "stem": key,
            "name": sysfs(node, "name") or key,
            "vendor": sysfs(node, "id", "vendor"),
            "product": sysfs(node, "id", "product"),
            "kind": "other",
            "keys": False,
            "pointer": False,
            "monitor": SETS.get(key),
            "nodes": [],
        })
        nm = sysfs(node, "name")
        # Ноды одной железки называются "X", "X Consumer Control", "X System
        # Control" — базовое имя всегда самое короткое.
        if nm and (d["name"] == key or len(nm) < len(d["name"])):
            d["name"] = nm
        k = kind_of(node)
        if k == "keyboard":
            d["keys"] = True
        elif k == "mouse":
            d["pointer"] = True
        d["nodes"].append({
            "id": name,
            "node": node,
            "kind": k,
            "grab": name in GRAB,
            "access": os.access(path, os.R_OK | os.W_OK),
        })
    out = list(devices.values())
    for d in out:
        d["access"] = all(n["access"] for n in d["nodes"])
        # Комбо — не ошибка определения, а правда: у игровых мышей есть
        # интерфейс с макро-клавишами, у диванных клавиатур — тачпад.
        d["kind"] = ("combo" if d["keys"] and d["pointer"]
                     else "keyboard" if d["keys"]
                     else "mouse" if d["pointer"] else "other")
    return out


def udev_rule(devices):
    """Правило под выбранные железки. Номер 70 обязателен: 73-seat-late.rules
    проверяет TAG=="uaccess" раньше, и правило с большим номером опоздает.
    Комментарии — только отдельной строкой, инлайновых udev не понимает."""
    lines = [
        "# Сгенерировано screen-owner. Доступ к вводу только активной сессии.",
        "# Файл обязан называться 70-screen-owner.rules, не выше по номеру.",
        "",
    ]
    seen = set()
    for d in sorted(devices, key=lambda x: x["stem"]):
        vid, pid = d.get("vendor"), d.get("product")
        if not vid or not pid or (vid, pid) in seen:
            continue
        seen.add((vid, pid))
        lines.append(f"# {d['name']}")
        lines.append(f'SUBSYSTEM=="input", ATTRS{{idVendor}}=="{vid}", '
                     f'ATTRS{{idProduct}}=="{pid}", TAG+="uaccess"')
    return "\n".join(lines) + "\n"


def scan(sel, opened, clones, denied):
    for name in os.listdir(BYID):
        mon = owner(name)
        if not mon or "event" not in name or name in opened:
            continue
        try:
            dev = InputDevice(f"{BYID}/{name}")
        except PermissionError:
            if name not in denied:
                denied.add(name)
                print(f"нет доступа: {name}  (udev-правило не установлено?)")
            continue
        except OSError:
            continue  # железку выдернули прямо сейчас
        denied.discard(name)
        note = ""
        if name in GRAB and not NOGRAB:
            try:
                clones[name] = UInput.from_device(dev, name=f"{dev.name} (screen-owner)")
                dev.grab()
                note = "  [перехват]"
            except OSError as e:  # уже держит другой экземпляр демона
                ui = clones.pop(name, None)
                if ui:
                    ui.close()
                note = f"  [перехват не вышел: {e}]"
        opened[name] = dev
        sel.register(dev, selectors.EVENT_READ, (name, mon))
        print(f"слушаю {name} -> {mon}{note}")


def drop(sel, opened, clones, name):
    """Убрать отвалившееся устройство: снять захват, закрыть копию и ноду."""
    dev = opened.pop(name, None)
    if dev is None:
        return
    try:
        sel.unregister(dev)
    except (KeyError, ValueError):
        pass
    ui = clones.pop(name, None)
    if ui:
        try:
            dev.ungrab()
        except OSError:
            pass
        ui.close()
    try:
        dev.close()
    except OSError:
        pass
    print(f"отвалилось {name}")


def reap(sel, opened, clones):
    """Железку могли выдернуть без ошибки чтения — тогда симлинка уже нет
    или он уехал на другую ноду. Без этой уборки повторное подключение
    того же имени scan() пропустит как «уже открытое»."""
    for name, dev in list(opened.items()):
        link = f"{BYID}/{name}"
        # dev.path — это путь, которым открывали, то есть сам симлинк.
        # Сравнивать надо разрешённые пути, иначе не совпадёт никогда.
        if not os.path.exists(link) or os.path.realpath(link) != os.path.realpath(dev.path):
            drop(sel, opened, clones, name)


def release(opened, clones):
    for name, dev in opened.items():
        if name in clones:
            try:
                dev.ungrab()
            except OSError:
                pass
    for ui in clones.values():
        ui.close()


def main():
    global SETS, GRAB
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))  # чтобы finally отработал
    SETS, GRAB = load_config()
    cfg_seen = config_mtime()

    sel = selectors.DefaultSelector()
    events = socket.socket(socket.AF_UNIX)
    events.connect(DIR + "/.socket2.sock")
    sel.register(events, selectors.EVENT_READ, (None, None))

    opened, clones, denied = {}, {}, set()
    scan(sel, opened, clones, denied)
    if not opened:
        sys.exit("ни одного устройства не открыть — поставь udev-правило и переткни донгл")

    try:
        present, current = monitors()
        last = {}  # монитор -> где на нём последний раз был курсор
        print(f"мониторы: {', '.join(sorted(present))}; сейчас в фокусе {current}")
        last_scan = time.time()

        while True:
            for key, _ in sel.select(timeout=RESCAN):
                name, mon = key.data

                if name is None:  # события Hyprland
                    for line in events.recv(1 << 13).decode().splitlines():
                        if line.startswith("focusedmon>>"):
                            current = line.split(">>", 1)[1].split(",")[0]
                        elif line.startswith(("monitoradded", "monitorremoved")):
                            present, current = monitors()
                            last = {k: v for k, v in last.items() if k in present}
                    continue

                try:  # события ввода
                    batch = list(key.fileobj.read())
                except OSError:
                    drop(sel, opened, clones, name)
                    continue

                intent = any(e.type in INTENT for e in batch)
                if intent and mon in present and mon != current:
                    here = cursorpos()
                    if current in present and here:
                        last[current] = here  # запомнить, куда вернуться
                    x, y = last.get(mon, present[mon])
                    # Порядок важен. follow_mouse на телепортацию курсора не
                    # реагирует, а focus после cursor.move уже пустышка: Hyprland
                    # считает активным монитор под курсором. Значит сначала фокус
                    # (он же утащит курсор), а потом курсор в запомненную точку.
                    hypr(f'dispatch hl.dsp.focus{{monitor = "{mon}"}}')
                    hypr(f"dispatch hl.dsp.cursor.move{{x = {x}, y = {y}}}")
                    print(f"{name} -> {mon} ({x}, {y})")
                    current = mon  # оптимистично, иначе улетит пачка повторов
                elif DEBUG and intent:
                    print(f"    пропуск: {name[:40]} набор={mon} current={current}")

                ui = clones.get(name)  # перехваченное отдаём уже после переключения
                if ui:
                    for e in batch:
                        ui.write_event(e)

            if time.time() - last_scan > RESCAN:
                if config_mtime() != cfg_seen:
                    cfg_seen = config_mtime()
                    SETS, GRAB = load_config()
                    print("конфиг перечитан, переоткрываю устройства")
                    for name in list(opened):  # привязки и перехваты поменялись
                        drop(sel, opened, clones, name)
                    denied.clear()
                reap(sel, opened, clones)   # сначала убрать выдернутое,
                scan(sel, opened, clones, denied)  # потом подобрать воткнутое
                last_scan = time.time()
    finally:
        release(opened, clones)


def cli(argv):
    """Команды для панели noctalia. Без аргументов запускается демон."""
    global SETS, GRAB
    SETS, GRAB = load_config()
    cmd = argv[0]

    if cmd == "devices":
        print(json.dumps(inventory(), ensure_ascii=False, indent=2))

    elif cmd == "monitors":
        present, current = monitors()
        print(json.dumps({"monitors": [{"name": n, "center": present[n],
                                        "focused": n == current}
                                       for n in sorted(present)]},
                         ensure_ascii=False, indent=2))

    elif cmd == "assign":
        if len(argv) != 3:
            sys.exit("assign <префикс-железки> <монитор|none>")
        prefix, mon = argv[1], argv[2]
        if mon == "none":
            SETS.pop(prefix, None)
            GRAB = {g for g in GRAB if not g.startswith(prefix)}
        else:
            SETS[prefix] = mon
        save_config(SETS, GRAB)
        print(f"{prefix} -> {mon}")

    elif cmd == "grab":
        if len(argv) != 3 or argv[2] not in ("on", "off"):
            sys.exit("grab <нода> <on|off>")
        node, on = argv[1], argv[2] == "on"
        GRAB = (GRAB | {node}) if on else (GRAB - {node})
        save_config(SETS, GRAB)
        print(f"перехват {node}: {argv[2]}")

    elif cmd == "udev-rule":
        assigned = [d for d in inventory() if d["monitor"]]
        rule = udev_rule(assigned)
        target = "/etc/udev/rules.d/70-screen-owner.rules"
        if "--install" in argv:  # запускать под pkexec/sudo
            with open(target, "w") as f:
                f.write(rule)
            os.system("udevadm control --reload")
            os.system("udevadm trigger --action=add --subsystem-match=input")
            print(f"правило записано в {target}")
        else:
            sys.stdout.write(rule)

    else:
        sys.exit(f"неизвестная команда: {cmd}")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        cli(sys.argv[1:])
    else:
        main()
