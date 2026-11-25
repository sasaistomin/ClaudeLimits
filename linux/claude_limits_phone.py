# ClaudeLimits — виджет на телефоне (Scriptable): лимиты выгружаются в секретный GitHub Gist,
# виджет на iPhone читает его по ID. Настройки — ~/.claude/limits-phone.json {"token", "gist_id"} (права 600).
#
#   python3 claude_limits_phone.py setup     — спросить токен GitHub (право gist), создать gist, сохранить настройки
#   python3 claude_limits_phone.py disable   — удалить настройки (сам gist остаётся на GitHub)
#   python3 claude_limits_phone.py status    — показать, настроено ли
#
# Значок в трее сам выгружает данные (PhoneSync), не чаще раза в минуту и только когда цифры изменились.
import getpass
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

import claude_limits_core as core

GIST_FILE = 'claude-limits.json'
MIN_INTERVAL = 60
RETRY_AFTER = 300


def api_base():
    return os.environ.get('CLAUDE_LIMITS_GITHUB_API', 'https://api.github.com').rstrip('/')


def config_path():
    return os.path.join(core.claude_dir(), 'limits-phone.json')


def read_phone_config(path=None):
    try:
        with open(path or config_path(), encoding='utf-8') as f:
            c = json.load(f)
        token, gist = c.get('token'), c.get('gist_id')
        if isinstance(token, str) and token and isinstance(gist, str) and gist:
            return {'token': token, 'gist_id': gist}
    except Exception:
        pass
    return None


def save_phone_config(token, gist_id, path=None):
    path = path or config_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path + '.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump({'token': token, 'gist_id': gist_id}, f, indent=2)
    os.replace(path + '.tmp', path)
    os.chmod(path, 0o600)


def payload(metrics, now=None):
    """Снимок для виджета: только источники с данными, проценты как есть (виджет сам обнуляет прошедшие окна)."""
    sources = {}
    for source in core.SOURCES:
        m = metrics.get(source)
        if not core.ok_metrics(m):
            continue
        sources[source] = {
            'updated': int(m.updated or 0),
            'windows': [{'id': w['id'], 'used': w['raw'], 'resets_at': int(w['reset']), 'rolling': bool(w['rolling'])}
                        for w in m.windows],
        }
    return {'v': 1, 'sent_at': int(time.time() if now is None else now), 'sources': sources}


def payload_key(p):
    return json.dumps(p.get('sources', {}), sort_keys=True)


def should_send(key, last_key, last_sent, failed_at, now):
    if key == last_key:
        return False
    if now - last_sent < MIN_INTERVAL:
        return False
    return not failed_at or now - failed_at >= RETRY_AFTER


def _request(method, url, token, body=None, timeout=20):
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        'Authorization': 'Bearer ' + token,
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'ClaudeLimits',
        'Content-Type': 'application/json',
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8') or '{}')


def gist_body(p):
    return {'files': {GIST_FILE: {'content': json.dumps(p, indent=1)}}}


def create_gist(token, p):
    body = gist_body(p)
    body.update({'description': 'Claude Limits — widget data', 'public': False})
    return _request('POST', api_base() + '/gists', token, body)['id']


def update_gist(token, gist_id, p):
    _request('PATCH', '{0}/gists/{1}'.format(api_base(), gist_id), token, gist_body(p))


class PhoneSync:
    """Фоновая выгрузка для значка в трее: offer() на каждый новый снимок, tick() раз в несколько секунд."""

    def __init__(self, path=None, send=update_gist, clock=time.time):
        self.path = path or config_path()
        self.send = send
        self.clock = clock
        self.cfg = None
        self.cfg_stamp = None
        self.pending = None
        self.last_key = None
        self.last_sent = 0.0
        self.failed_at = 0.0
        self.error = None
        self.busy = False
        self.lock = threading.Lock()

    def reload(self):
        try:
            st = os.stat(self.path)
            stamp = (st.st_size, st.st_mtime)
        except OSError:
            stamp = None
        if stamp != self.cfg_stamp:
            self.cfg_stamp = stamp
            self.cfg = read_phone_config(self.path) if stamp else None
            self.last_key, self.failed_at, self.error = None, 0.0, None
        return self.cfg

    @property
    def enabled(self):
        return self.cfg is not None

    def offer(self, metrics):
        self.pending = metrics

    def tick(self, background=True):
        if not self.reload() or self.pending is None or self.busy:
            return False
        now = self.clock()
        p = payload(self.pending, now)
        key = payload_key(p)
        if not p['sources'] or not should_send(key, self.last_key, self.last_sent, self.failed_at, now):
            return False
        self.busy = True
        cfg = self.cfg
        if background:
            threading.Thread(target=self._upload, args=(cfg, p, key), daemon=True).start()
        else:
            self._upload(cfg, p, key)
        return True

    def _upload(self, cfg, p, key):
        try:
            self.send(cfg['token'], cfg['gist_id'], p)
            with self.lock:
                self.last_key, self.last_sent, self.failed_at, self.error = key, self.clock(), 0.0, None
        except Exception as e:
            with self.lock:
                self.failed_at, self.error = self.clock(), str(e)
        finally:
            self.busy = False


def _http_error_text(e):
    if isinstance(e, urllib.error.HTTPError):
        e.close()
        if e.code == 401:
            return 'GitHub не принял токен (401). Проверьте, что он скопирован целиком и не просрочен.'
        if e.code in (403, 404):
            return 'У токена нет доступа к gist ({0}). Нужен classic-токен с галочкой «gist».'.format(e.code)
        return 'GitHub ответил {0}.'.format(e.code)
    return 'Нет связи с GitHub: {0}'.format(e)


def setup(token=None):
    print('Виджет Claude Limits для iPhone (Scriptable)')
    print('Нужен токен GitHub с правом «gist»: https://github.com/settings/tokens/new?scopes=gist&description=Claude%20Limits')
    token = (token or os.environ.get('CLAUDE_LIMITS_GITHUB_TOKEN') or getpass.getpass('Токен (ввод скрыт): ')).strip()
    if not token:
        print('Токен не введён.')
        return 1
    old = read_phone_config()
    p = {'v': 1, 'sent_at': int(time.time()), 'sources': {}}
    try:
        gist_id = None
        if old and old['token'] == token:
            try:
                update_gist(token, old['gist_id'], p)
                gist_id = old['gist_id']
            except urllib.error.HTTPError as e:
                e.close()
                if e.code != 404:
                    raise
        gist_id = gist_id or create_gist(token, p)
    except Exception as e:
        print(_http_error_text(e))
        return 1
    save_phone_config(token, gist_id)
    print('')
    print('Готово. Настройки: {0}'.format(config_path()))
    print('ID для виджета:  {0}'.format(gist_id))
    print('Вставьте его в поле Parameter виджета Scriptable (или в GIST_ID в начале скрипта).')
    print('Значок в трее начнёт выгружать цифры в течение минуты после следующего ответа Claude.')
    return 0


def disable():
    try:
        os.remove(config_path())
        print('Выгрузка для виджета выключена. Сам gist можно удалить на https://gist.github.com/')
    except FileNotFoundError:
        print('Выгрузка для виджета и так не настроена.')
    return 0


def status():
    cfg = read_phone_config()
    print('Настроено, ID для виджета: {0}'.format(cfg['gist_id']) if cfg else 'Не настроено. Запустите: setup')
    return 0


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    sys.exit({'setup': setup, 'disable': disable, 'status': status}.get(cmd, status)())
