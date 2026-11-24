# ClaudeLimits for Linux — логика без интерфейса (тексты, настройки, данные, уведомления, график).
# Только стандартная библиотека Python 3. Подключается из statusline.py, claude_limits.py и тестов.
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
        'low_title': 'Claude: осталось {0}%',
        'low_body_five': '5-часовое окно израсходовано на {0}%. Сброс {1}.',
        'low_body_week': 'Недельный лимит израсходован на {0}%. Сброс {1}.',
        'reset_title': 'Лимит Claude сброшен',
        'reset_body_five': '5-часовое окно обновилось — можно работать.',
        'reset_body_week': 'Недельный лимит обновился — можно работать.',
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
        'low_title': 'Claude: {0}% left',
        'low_body_five': '5-hour window is {0}% used. Resets {1}.',
        'low_body_week': 'Weekly limit is {0}% used. Resets {1}.',
        'reset_title': 'Claude limit has reset',
        'reset_body_five': "The 5-hour window has reset — you're good to go.",
        'reset_body_week': "The weekly limit has reset — you're good to go.",
        'chart': 'Usage chart…', 'chart_title': 'Claude Limits — chart',
        'chart_no_data': "The window has reset. The chart will appear after Claude Code's next reply.",
        'forecast_at': "Forecast: at this pace you'll hit the limit {0}",
        'forecast_ok': 'Forecast: at this pace the limit will last until reset',
        'days': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'], 'at': 'at',
    },
}

FIVE, WEEK = 'five_hour', 'seven_day'
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
    cfg = {'language': 'system', 'notifications': True, 'notified': {}}
    try:
        with open(path, encoding='utf-8') as f:
            c = json.load(f)
        if c.get('language') in ('system', 'ru', 'en'):
            cfg['language'] = c['language']
        if isinstance(c.get('notifications'), bool):
            cfg['notifications'] = c['notifications']
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

def indicator_label(limits):
    """Короткая надпись рядом со значком: остаток 5-часового окна (или недели)."""
    if not limits:
        return '—'
    w = limits.get(FIVE) or limits.get(WEEK)
    return '{0}%'.format(int(round(w['left']))) if w else '—'

def worst_used(limits):
    if not limits:
        return None
    vals = [w['used'] for w in (limits.get(FIVE), limits.get(WEEK)) if w]
    return max(vals) if vals else None


# ---------- уведомления (решение, без отправки) ----------

def notify_event(key, window, notified, now=None):
    """notified — dict «ключ -> resets_at окна, о котором уже сообщали»; функция его дополняет.
    Возвращает {'type': 'low', 'threshold', 'used'} / {'type': 'reset'} / None."""
    now = time.time() if now is None else now
    w = window

    def already(k):
        return k in notified and abs(notified[k] - w['reset']) < 1800

    if now < w['reset']:
        for th in (95, 80):
            if w['raw'] >= th:
                if already('{0}:{1}'.format(key, th)):
                    return None
                for t2 in (95, 80):
                    if t2 <= th:
                        notified['{0}:{1}'.format(key, t2)] = float(w['reset'])
                return {'type': 'low', 'threshold': th, 'used': int(round(w['raw']))}
        return None
    if now - w['reset'] < 900 and w['raw'] >= 80 and not already(key + ':reset'):
        notified[key + ':reset'] = float(w['reset'])
        return {'type': 'reset'}
    return None

def format_notification(ev, window, five, t, now=None):
    """-> (title, body, urgency 'normal'|'critical')"""
    if ev['type'] == 'reset':
        return t['reset_title'], t['reset_body_five' if five else 'reset_body_week'], 'normal'
    body = t['low_body_five' if five else 'low_body_week'].format(ev['used'], format_countdown(window['reset'], t, now))
    return (t['low_title'].format(max(0, 100 - ev['used'])), body,
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
    elif cmd == 'uninstall':
        remove_statusline()
        set_autostart(False, '')
    else:
        print('usage: claude_limits_core.py install <dir> | uninstall')
        sys.exit(2)
