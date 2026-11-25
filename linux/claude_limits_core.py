# ClaudeLimits for Linux — логика без интерфейса (тексты, настройки, карточки, уведомления, график).
# Данные читают парсеры (claude_limits_parsers.py), опрос ведёт LimitMonitoringService (claude_limits_monitor.py).
# Только стандартная библиотека Python 3. Подключается из statusline.py, claude_limits.py и тестов.
import itertools
import json
import math
import os
import shutil
import time

STRINGS = {
    'ru': {
        'title': 'Лимиты Claude', 'five': '5 часов', 'week': 'Неделя',
        'no_data': 'нет данных', 'no_data_long': 'Пока нет данных — отправьте любое сообщение в Claude Code',
        'left_used': '{0}: осталось {1}% (использовано {2}%)', 'reset': 'сброс {0}',
        'done': 'сброшен', 'in_dh': 'через {0} д {1} ч', 'in_hm': 'через {0} ч {1} мин', 'in_m': 'через {0} мин',
        'updated': 'Обновлено {0}', 'just_now': 'только что', 'min_ago': '{0} мин назад',
        'h_ago': '{0} ч назад', 'd_ago': '{0} д назад',
        'startup': 'Запускать при входе в систему', 'language': 'Язык', 'system': 'Системный', 'quit': 'Выход',
        'notifications': 'Уведомления',
        'notif_on_title': 'Уведомления включены',
        'notif_on_body': 'Сообщу, когда лимит будет заканчиваться и когда он сбросится.',
        'low_title': '[{0}] Осталось {1}%',
        'low_body_five': '5-часовое окно израсходовано на {0}%. Сброс {1}.',
        'low_body_week': 'Недельный лимит израсходован на {0}%. Сброс {1}.',
        'low_body_rolling': '5-часовое окно сообщений израсходовано на {0}%. Сброс в {1}.',
        'exhausted_body_rolling': '5-часовое окно сообщений исчерпано. Сброс в {1}.',
        'reset_title': '[{0}] Лимит сброшен',
        'reset_body_five': '5-часовое окно обновилось — можно работать.',
        'reset_body_week': 'Недельный лимит обновился — можно работать.',
        'reset_body_rolling': '5-часовое окно сообщений обновилось — можно работать.',
        'rolling': 'Окно 5 ч (скользящее)', 'reset_at': 'сброс в {0} ({1})', 'loading': 'Загрузка…',
        'desktop_not_found': 'Claude Desktop: не подключено',
        'desktop_not_found_hint': 'Логи не найдены — укажите папку в меню «Claude Desktop»',
        'desktop_no_data': 'Лимиты пока не записаны — отправьте сообщение в Claude Desktop',
        'desktop_folder': 'Claude Desktop', 'desktop_auto': 'Находить папку автоматически',
        'desktop_pick': 'Указать папку данных…', 'desktop_pick_title': 'Папка данных Claude Desktop (обычно ~/.config/Claude)',
        'desktop_no_path': 'Папка не найдена', 'tip_five': '5ч', 'tip_week': 'неделя',
        'check_updates': 'Проверить обновления', 'checking_updates': 'Проверяю обновления…',
        'up_to_date': 'Установлена последняя версия ({0})', 'update_to': 'Обновить до версии {0}',
        'update_failed': 'Не удалось проверить обновления — повторить', 'installing_update': 'Устанавливаю обновление…',
        'chart': 'График использования…', 'chart_title': 'Лимиты Claude — график',
        'chart_no_data': 'Окно сбросилось. График появится после следующего ответа Claude Code.',
        'forecast_at': 'Прогноз: при таком темпе лимит закончится {0}',
        'forecast_ok': 'Прогноз: при таком темпе лимита хватит до сброса',
        'days': ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'], 'at': 'в',
    },
    'en': {
        'title': 'Claude Limits', 'five': '5 hours', 'week': 'Weekly',
        'no_data': 'no data', 'no_data_long': 'No data yet — send any message in Claude Code',
        'left_used': '{0}: {1}% left ({2}% used)', 'reset': 'resets {0}',
        'done': 'done', 'in_dh': 'in {0}d {1}h', 'in_hm': 'in {0}h {1}m', 'in_m': 'in {0}m',
        'updated': 'Updated {0}', 'just_now': 'just now', 'min_ago': '{0} min ago',
        'h_ago': '{0} h ago', 'd_ago': '{0} d ago',
        'startup': 'Launch at login', 'language': 'Language', 'system': 'System', 'quit': 'Quit',
        'notifications': 'Notifications',
        'notif_on_title': 'Notifications are on',
        'notif_on_body': "I'll let you know when a limit is running low and when it resets.",
        'low_title': '[{0}] {1}% left',
        'low_body_five': '5-hour window is {0}% used. Resets {1}.',
        'low_body_week': 'Weekly limit is {0}% used. Resets {1}.',
        'low_body_rolling': '5-hour message window is {0}% used. Resets at {1}.',
        'exhausted_body_rolling': '5-hour message window is used up. Resets at {1}.',
        'reset_title': '[{0}] Limit has reset',
        'reset_body_five': "The 5-hour window has reset — you're good to go.",
        'reset_body_week': "The weekly limit has reset — you're good to go.",
        'reset_body_rolling': "The 5-hour message window has reset — you're good to go.",
        'rolling': '5-hour window (rolling)', 'reset_at': 'resets at {0} ({1})', 'loading': 'Loading…',
        'desktop_not_found': 'Claude Desktop: not connected',
        'desktop_not_found_hint': 'Logs not found — set the folder in the «Claude Desktop» menu',
        'desktop_no_data': 'No limits recorded yet — send a message in Claude Desktop',
        'desktop_folder': 'Claude Desktop', 'desktop_auto': 'Find the folder automatically',
        'desktop_pick': 'Choose data folder…', 'desktop_pick_title': 'Claude Desktop data folder (usually ~/.config/Claude)',
        'desktop_no_path': 'Folder not found', 'tip_five': '5h', 'tip_week': 'week',
        'check_updates': 'Check for updates', 'checking_updates': 'Checking for updates…',
        'up_to_date': 'Up to date ({0})', 'update_to': 'Update to {0}',
        'update_failed': "Couldn't check for updates — retry", 'installing_update': 'Installing update…',
        'chart': 'Usage chart…', 'chart_title': 'Claude Limits — chart',
        'chart_no_data': "The window has reset. The chart will appear after Claude Code's next reply.",
        'forecast_at': "Forecast: at this pace you'll hit the limit {0}",
        'forecast_ok': 'Forecast: at this pace the limit will last until reset',
        'days': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'], 'at': 'at',
    },
}

FIVE, WEEK = 'five_hour', 'seven_day'
SOURCES = ('code', 'desktop')
SOURCE_NAMES = {'code': 'Claude Code', 'desktop': 'Claude Desktop'}
DURATION = {FIVE: 5 * 3600, WEEK: 7 * 86400}
HISTORY_MAX_BYTES = 512 * 1024
HISTORY_KEEP_DAYS = 8
MARKER = 'claude-limits'          # так мы узнаём «свой» statusLine в settings.json


# ---------- пути (всё от HOME, чтобы тесты могли подменить) ----------

def home():
    return os.environ.get('HOME') or os.path.expanduser('~')

def claude_dir():
    return os.path.join(home(), '.claude')

def limits_path():
    return os.path.join(claude_dir(), 'limits.json')

def history_path():
    return os.path.join(claude_dir(), 'limits-history.jsonl')

def desktop_history_path():
    """История вкладки Claude Desktop: её пишет само приложение при каждом новом снимке."""
    return os.path.join(claude_dir(), 'limits-desktop-history.jsonl')

def settings_path():
    return os.path.join(claude_dir(), 'settings.json')

def config_dir():
    base = os.environ.get('XDG_CONFIG_HOME') or os.path.join(home(), '.config')
    return os.path.join(base, 'claude-limits')

def autostart_path():
    base = os.environ.get('XDG_CONFIG_HOME') or os.path.join(home(), '.config')
    return os.path.join(base, 'autostart', 'claude-limits.desktop')


# ---------- язык и настройки ----------

def resolve_lang(setting, env=None):
    if setting in ('ru', 'en'):
        return setting
    env = os.environ if env is None else env
    for k in ('LC_ALL', 'LC_MESSAGES', 'LANGUAGE', 'LANG'):
        v = env.get(k)
        if v:
            return 'ru' if v.lower().startswith('ru') else 'en'
    return 'en'

def read_config(path=None):
    path = path or os.path.join(config_dir(), 'config.json')
    cfg = {'language': 'system', 'notifications': True, 'notified': {}, 'active_tab': 0, 'desktop_path': ''}
    try:
        with open(path, encoding='utf-8') as f:
            c = json.load(f)
        if c.get('language') in ('system', 'ru', 'en'):
            cfg['language'] = c['language']
        if isinstance(c.get('notifications'), bool):
            cfg['notifications'] = c['notifications']
        tab = c.get('active_tab')
        if isinstance(tab, int) and not isinstance(tab, bool) and 0 <= tab < len(SOURCES):
            cfg['active_tab'] = tab
        if isinstance(c.get('desktop_path'), str):
            cfg['desktop_path'] = c['desktop_path']
        if isinstance(c.get('notified'), dict):
            cfg['notified'] = {k: float(v) for k, v in c['notified'].items()}
    except Exception:
        pass
    return cfg

def save_config(cfg, path=None):
    path = path or os.path.join(config_dir(), 'config.json')
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        write_atomic(path, json.dumps(cfg, ensure_ascii=False, indent=2))
    except Exception:
        pass

def write_atomic(path, text):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(text)
    os.replace(tmp, path)


# ---------- данные ----------

def read_limits(path=None, now=None):
    """limits.json -> {'updated', 'model', FIVE: {...}|None, WEEK: {...}|None} или None.
    Окно, время сброса которого прошло, считается обнулённым (used = 0, raw = как было)."""
    now = time.time() if now is None else now
    try:
        with open(path or limits_path(), encoding='utf-8') as f:
            d = json.load(f)
        rl = d['rate_limits']
    except Exception:
        return None
    if not isinstance(rl, dict):
        return None
    res = {'updated': float(d.get('updated_at') or 0), 'model': d.get('model'), FIVE: None, WEEK: None}
    for k in (FIVE, WEEK):
        w = rl.get(k)
        if isinstance(w, dict) and w.get('used_percentage') is not None:
            raw = float(w['used_percentage'])
            reset = int(w.get('resets_at') or 0)
            used = 0.0 if reset < now else raw
            res[k] = {'used': used, 'raw': raw, 'left': max(0.0, 100 - used), 'reset': reset}
    return res

def format_countdown(reset_at, t, now=None):
    now = time.time() if now is None else now
    s = int(reset_at - now)
    if s <= 0:
        return t['done']
    d, h, m = s // 86400, (s % 86400) // 3600, (s % 3600) // 60
    if d > 0:
        return t['in_dh'].format(d, h)
    if h > 0:
        return t['in_hm'].format(h, m)
    return t['in_m'].format(m)

def format_ago(ts, t, now=None):
    now = time.time() if now is None else now
    s = int(now - ts)
    if s < 60:
        return t['just_now']
    if s < 3600:
        return t['min_ago'].format(s // 60)
    if s < 86400:
        return t['h_ago'].format(s // 3600)
    return t['d_ago'].format(s // 86400)

def format_clock(ts, t, with_day):
    lt = time.localtime(ts)
    hm = time.strftime('%H:%M', lt)
    return '{0} {1}'.format(t['days'][lt.tm_wday], hm) if with_day else '{0} {1}'.format(t['at'], hm)

def level(used):
    """'green' | 'yellow' | 'red'"""
    if used >= 90:
        return 'red'
    if used >= 70:
        return 'yellow'
    return 'green'

def ok_metrics(m):
    return m is not None and m.status == 'Ok' and bool(m.windows)

def indicator_label(m):
    """Короткая надпись рядом со значком: остаток первого окна активной вкладки."""
    return '{0}%'.format(int(round(m.windows[0]['left']))) if ok_metrics(m) else '—'

def worst_used(m):
    return max(w['used'] for w in m.windows) if ok_metrics(m) else None

def tray_tooltip(metrics, t):
    """Подсказка по всем источникам с данными: «Code: 5h 86% · week 49% | Desktop: 5h 82%»."""
    parts = []
    for m in metrics:
        if ok_metrics(m):
            ws = ' · '.join('{0} {1}%'.format(t['tip_five'] if w['id'] == FIVE else t['tip_week'], int(round(w['left'])))
                            for w in m.windows)
            parts.append('{0}: {1}'.format(SOURCE_NAMES[m.source].split()[-1], ws))
    return ' | '.join(parts) if parts else t['no_data_long']

def window_lines(w, t, now=None):
    """Две строки карточки окна: «что осталось» и «когда сброс». Скользящее окно Desktop — со временем сброса."""
    now = time.time() if now is None else now
    label = t['rolling'] if w.get('rolling') else t['five'] if w['id'] == FIVE else t['week']
    main = t['left_used'].format(label, int(round(w['left'])), int(round(w['used'])))
    countdown = format_countdown(w['reset'], t, now)
    if w.get('rolling') and w['reset'] > now:
        reset = t['reset_at'].format(time.strftime('%H:%M', time.localtime(w['reset'])), countdown)
    else:
        reset = t['reset'].format(countdown)
    return main, '    ' + reset

def empty_state_lines(source, m, t):
    """Текст вкладки без данных: загрузка / не подключено / нет данных."""
    if m is None:
        return t['loading'], ''
    if source == 'desktop':
        if m.status == 'NotFound':
            return t['desktop_not_found'], t['desktop_not_found_hint']
        return t['desktop_no_data'], ''
    return t['no_data_long'], ''


# ---------- уведомления (решение, без отправки) ----------

def notify_key(source, w):
    return w['id'] if source == 'code' else '{0}:{1}'.format(source, w['id'])

def notify_thresholds(w):
    return (100, 95, 80) if w.get('rolling') else (95, 80)

def notify_event(key, window, notified, now=None, thresholds=(95, 80)):
    """notified — dict «ключ -> resets_at окна, о котором уже сообщали»; функция его дополняет.
    Возвращает {'type': 'low', 'threshold', 'used'} / {'type': 'reset'} / None."""
    now = time.time() if now is None else now
    w = window

    def already(k):
        return k in notified and abs(notified[k] - w['reset']) < 1800

    if now < w['reset']:
        levels = sorted(thresholds, reverse=True)
        for th in levels:
            if w['raw'] >= th:
                if already('{0}:{1}'.format(key, th)):
                    return None
                for t2 in levels:
                    if t2 <= th:
                        notified['{0}:{1}'.format(key, t2)] = float(w['reset'])
                return {'type': 'low', 'threshold': th, 'used': int(round(w['raw']))}
        return None
    if now - w['reset'] < 900 and w['raw'] >= 80 and not already(key + ':reset'):
        notified[key + ':reset'] = float(w['reset'])
        return {'type': 'reset'}
    return None

def format_notification(ev, window, source, t, now=None):
    """-> (title, body, urgency 'normal'|'critical'); источник — в заголовке."""
    name = SOURCE_NAMES[source]
    kind = 'rolling' if window.get('rolling') else 'five' if window.get('id', FIVE) == FIVE else 'week'
    if ev['type'] == 'reset':
        return t['reset_title'].format(name), t['reset_body_' + kind], 'normal'
    if kind == 'rolling':
        when = time.strftime('%H:%M', time.localtime(window['reset']))
        fmt = t['exhausted_body_rolling'] if ev['threshold'] >= 100 else t['low_body_rolling']
    else:
        when, fmt = format_countdown(window['reset'], t, now), t['low_body_' + kind]
    return (t['low_title'].format(name, max(0, 100 - ev['used'])), fmt.format(ev['used'], when),
            'critical' if ev['threshold'] >= 95 else 'normal')


# ---------- история и график ----------

def read_history(path=None):
    out = []
    try:
        with open(path or history_path(), encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    pass
    except Exception:
        pass
    return out

def _used(rl, k):
    w = (rl or {}).get(k) if isinstance(rl, dict) else None
    return float(w['used_percentage']) if isinstance(w, dict) and w.get('used_percentage') is not None else None

def append_history_if_changed(old_rl, new_rl, path=None, now=None):
    """Дописывает строку, если проценты изменились (или истории ещё нет). Возвращает True, если дописал."""
    path = path or history_path()
    now = int(time.time() if now is None else now)
    changed = _used(old_rl, FIVE) != _used(new_rl, FIVE) or _used(old_rl, WEEK) != _used(new_rl, WEEK)
    if not changed and os.path.exists(path):
        return False
    s = {'t': now}
    if isinstance(new_rl.get(FIVE), dict):
        s['f'] = _used(new_rl, FIVE); s['fr'] = int(new_rl[FIVE].get('resets_at') or 0)
    if isinstance(new_rl.get(WEEK), dict):
        s['w'] = _used(new_rl, WEEK); s['wr'] = int(new_rl[WEEK].get('resets_at') or 0)
    with open(path, 'a', encoding='utf-8') as f:
        f.write(json.dumps(s, separators=(',', ':')) + '\n')
    prune_history(path, now)
    return True

def append_metrics_history(m, path=None, now=None):
    """Дописывает снимок источника (Claude Desktop) и его прошлые замеры, если проценты изменились."""
    if m is None or m.status != 'Ok':
        return False
    path = path or desktop_history_path()
    hist = read_history(path)
    last = hist[-1] if hist else None
    lines = []
    for s in m.samples:
        if s['t'] > (last or {}).get('t', 0) and s['f'] != (last or {}).get('f'):
            last = {'t': int(s['t']), 'f': s['f'], 'fr': s['fr']}
            lines.append(last)
    f, w = m.window(FIVE), m.window(WEEK)
    if last is None or last.get('f') != (f and f['raw']) or last.get('w') != (w and w['raw']):
        cur = {'t': int(max(m.updated or (time.time() if now is None else now), (last or {}).get('t', 0)))}
        if f:
            cur['f'], cur['fr'] = f['raw'], int(f['reset'])
        if w:
            cur['w'], cur['wr'] = w['raw'], int(w['reset'])
        lines.append(cur)
    if not lines:
        return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'a', encoding='utf-8') as fh:
        fh.write(''.join(json.dumps(x, separators=(',', ':')) + '\n' for x in lines))
    prune_history(path, now)
    return True

def prune_history(path=None, now=None):
    path = path or history_path()
    now = time.time() if now is None else now
    try:
        if os.path.getsize(path) <= HISTORY_MAX_BYTES:
            return
        cutoff = now - HISTORY_KEEP_DAYS * 86400
        kept = [s for s in read_history(path) if isinstance(s, dict) and float(s.get('t', 0)) >= cutoff]
        write_atomic(path, ''.join(json.dumps(s, separators=(',', ':')) + '\n' for s in kept))
    except Exception:
        pass

def chart_model(limits, history, kind, now=None):
    """Точки текущего окна (от начала с 0% через историю к «сейчас») и прогноз по среднему темпу."""
    now = time.time() if now is None else now
    w = limits.get(kind) if limits else None
    if not w or w['reset'] <= now:
        return None
    start = w['reset'] - DURATION[kind]
    key = 'f' if kind == FIVE else 'w'
    pts = [(start, 0.0)]
    for s in history or []:
        if not isinstance(s, dict) or s.get(key) is None:
            continue
        t = float(s.get('t', 0))
        if start <= t <= now:
            if pts[-1][0] == t:
                pts.pop()
            pts.append((t, float(s[key])))
    pts.append((now, float(w['used'])))
    elapsed = now - start
    rate = w['used'] / elapsed if elapsed > 300 and w['used'] > 0 else 0.0
    run_out = None
    if rate > 0:
        t100 = now + (100 - w['used']) / rate
        if t100 < w['reset']:
            run_out = t100
    return {'kind': kind, 'start': start, 'end': w['reset'], 'now': now, 'used': w['used'],
            'points': pts, 'rate': rate, 'run_out': run_out}

def forecast_text(model, t):
    if not model:
        return t['chart_no_data']
    if model['run_out'] is None:
        return t['forecast_ok']
    return t['forecast_at'].format(format_clock(model['run_out'], t, model['kind'] == WEEK))


# ---------- statusline (вызывается Claude Code на каждое обновление) ----------

def statusline(raw_input, now=None):
    """Принимает JSON сессии, сохраняет rate_limits, возвращает строку статуса."""
    try:
        data = json.loads(raw_input)
        if not isinstance(data, dict):
            raise ValueError
    except Exception:
        return '[Claude]'
    model = ((data.get('model') or {}).get('display_name') if isinstance(data.get('model'), dict) else None) or 'Claude'
    rl = data.get('rate_limits')
    if isinstance(rl, dict) and rl:
        try:
            os.makedirs(claude_dir(), exist_ok=True)
            old = None
            try:
                with open(limits_path(), encoding='utf-8') as f:
                    old = json.load(f).get('rate_limits')
            except Exception:
                pass
            append_history_if_changed(old, rl, now=now)
            out = {'updated_at': int(time.time() if now is None else now), 'rate_limits': rl, 'model': model}
            write_atomic(limits_path(), json.dumps(out, ensure_ascii=False, indent=2))
        except Exception:
            pass
    parts = []
    for k, name in ((FIVE, '5h'), (WEEK, '7d')):
        u = _used(rl, k) if isinstance(rl, dict) else None
        if u is not None:
            parts.append('{0}: {1}%'.format(name, int(math.floor(u + 0.5))))
    return '[{0}]'.format(model) + (' ' + ' '.join(parts) if parts else '')


# ---------- settings.json Claude Code ----------

def statusline_command(install_dir):
    return 'python3 "{0}"'.format(os.path.join(install_dir, 'statusline.py'))

def set_statusline(command, path=None):
    """Прописывает наш statusLine, сохраняя остальные ключи. -> (ok, replaced_command|None).
    Битый JSON не трогает. Делает копию settings.json.bak."""
    path = path or settings_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    obj, replaced = {}, None
    if os.path.exists(path):
        with open(path, encoding='utf-8') as f:
            text = f.read()
        if text.strip():
            try:
                obj = json.loads(text)
            except Exception:
                return False, None
            if not isinstance(obj, dict):
                return False, None
        shutil.copyfile(path, path + '.bak')
        sl = obj.get('statusLine')
        if isinstance(sl, dict) and sl.get('command') and MARKER not in str(sl['command']):
            replaced = str(sl['command'])
    obj['statusLine'] = {'type': 'command', 'command': command}
    write_atomic(path, json.dumps(obj, ensure_ascii=False, indent=2) + '\n')
    return True, replaced

def remove_statusline(path=None):
    """Убирает statusLine, только если он наш. -> True, если что-то поменяли."""
    path = path or settings_path()
    try:
        with open(path, encoding='utf-8') as f:
            obj = json.load(f)
    except Exception:
        return False
    sl = obj.get('statusLine') if isinstance(obj, dict) else None
    if not (isinstance(sl, dict) and MARKER in str(sl.get('command', ''))):
        return False
    shutil.copyfile(path, path + '.bak')
    del obj['statusLine']
    write_atomic(path, json.dumps(obj, ensure_ascii=False, indent=2) + '\n')
    return True


# ---------- обновления (VERSION на GitHub, установка — тем же install.sh) ----------

def repo_raw():
    return os.environ.get('CLAUDE_LIMITS_REPO_RAW') or 'https://raw.githubusercontent.com/sasaistomin/ClaudeLimits/main'

def installed_version(install_dir=None):
    try:
        with open(os.path.join(install_dir or os.path.dirname(os.path.abspath(__file__)), 'VERSION'), encoding='utf-8') as f:
            return f.read().strip() or '0.0.0'
    except OSError:
        return '0.0.0'

def version_parts(v):
    """'v2.10.1-beta' -> [2, 10, 1]"""
    parts = []
    for p in str(v).strip().lstrip('vV').split('.'):
        digits = ''.join(itertools.takewhile(str.isdigit, p))
        parts.append(int(digits) if digits else 0)
    return parts

def is_newer(remote, local):
    """Новее ли remote, чем local. Пустая или нечисловая версия на сервере — не обновление."""
    r, l = version_parts(remote), version_parts(local)
    if not any(r):
        return False
    n = max(len(r), len(l))
    return r + [0] * (n - len(r)) > l + [0] * (n - len(l))

def fetch_remote_version(timeout=15):
    import urllib.request
    req = urllib.request.Request(repo_raw() + '/VERSION', headers={'User-Agent': 'ClaudeLimits', 'Cache-Control': 'no-cache'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(64).decode('utf-8', 'replace').strip()

def update_command():
    """Команда обновления: скачать install.sh и выполнить его (он остановит значок и запустит новый)."""
    return ['bash', '-c', 'curl -fsSL "$0/linux/install.sh" | bash', repo_raw()]


# ---------- автозапуск ----------

def autostart_entry(app_path):
    return ('[Desktop Entry]\nType=Application\nName=Claude Limits\n'
            'Comment=Claude usage limits in the tray\n'
            'Exec=python3 "{0}"\nIcon=utilities-system-monitor\nTerminal=false\n'
            'X-GNOME-Autostart-enabled=true\n').format(app_path)

def set_autostart(enabled, app_path):
    p = autostart_path()
    if enabled:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w', encoding='utf-8') as f:
            f.write(autostart_entry(app_path))
    elif os.path.exists(p):
        os.remove(p)

def autostart_enabled():
    return os.path.exists(autostart_path())


# ---------- командная строка установщика ----------

if __name__ == '__main__':
    import sys
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'install':          # install <install_dir>
        d = sys.argv[2]
        ok, replaced = set_statusline(statusline_command(d))
        if not ok:
            print('Ошибка: не удалось разобрать {0} — исправьте JSON и запустите установку снова.'.format(settings_path()))
            sys.exit(1)
        if replaced:
            print('Внимание: прежний statusLine ({0}) будет заменён. Копия: settings.json.bak'.format(replaced))
        set_autostart(True, os.path.join(d, 'claude_limits.py'))
        print('==> statusLine прописан в {0}'.format(settings_path()))
        sys.path.insert(0, d)
        import claude_limits_parsers as parsers
        cfg = read_config()
        print('==> Claude Code: {0}'.format(claude_dir()))
        desktop = parsers.new_parser('desktop', cfg['desktop_path'])
        if desktop.is_installed():
            print('==> Claude Desktop: {0}'.format(desktop.get_log_path()))
        else:
            print('==> Claude Desktop не найден: вкладка покажет «Не подключено». Папку можно указать в меню значка.')
        save_config(cfg)
    elif cmd == 'uninstall':
        remove_statusline()
        set_autostart(False, '')
    else:
        print('usage: claude_limits_core.py install <dir> | uninstall')
        sys.exit(2)
