# ClaudeLimits for Linux — слой парсеров (Strategy): один контракт LimitParser, по реализации на источник.
#   ClaudeCodeParser    — ~/.claude/limits.json, который пишет statusline.py
#   ClaudeDesktopParser — данные клиента Claude Desktop:
#     Local Storage (LevelDB): запись {"resetsAt","utilization","observedAt",...} — 5-часовое окно;
#     IndexedDB (кэш ответа claude.ai, V8 + Snappy): messageLimits.windows {"5h", "7d"} — 5-часовое и недельное окна.
# Журнал .log дочитывается с сохранённого offset, неизменяемые таблицы .ldb разбираются один раз
# и кэшируются по размеру и времени записи. Только стандартная библиотека Python 3.
import abc
import datetime
import os
import re
import struct
import time
from dataclasses import dataclass, field

import claude_limits_core as core

TABLE_MAGIC = 0xdb4775248b80fb57
RECORD_RE = re.compile(r'\{[^{}]{0,2048}?"resetsAt"[^{}]{0,2048}?\}')
RESET_RE = re.compile(r'"resetsAt"\s*:\s*(\d+(?:\.\d+)?)')
UTIL_RE = re.compile(r'"utilization"\s*:\s*(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)')
OBSERVED_RE = re.compile(r'"observedAt"\s*:\s*(\d+(?:\.\d+)?)')
AT_WALL_RE = re.compile(r'"atWall"\s*:\s*true')
JOURNAL_TAIL = 4096


@dataclass
class LimitMetrics:
    source: str
    status: str = 'NoData'
    updated: float = 0.0
    log_path: str = ''
    windows: list = field(default_factory=list)
    samples: list = field(default_factory=list)

    def window(self, wid):
        return next((w for w in self.windows if w['id'] == wid), None)


def make_window(wid, raw, reset, rolling, now):
    used = 0.0 if reset <= now else min(100.0, max(0.0, raw))
    return {'id': wid, 'used': used, 'raw': raw, 'left': max(0.0, 100 - used), 'reset': reset, 'rolling': rolling}


class LimitParser(abc.ABC):
    source = ''

    def parse_limits(self):
        return self.parse_at(time.time())

    @abc.abstractmethod
    def parse_at(self, now):
        ...

    @abc.abstractmethod
    def get_log_path(self):
        ...

    def is_installed(self):
        path = self.get_log_path()
        return bool(path) and os.path.exists(path)

    def get_reset_time(self):
        now = time.time()
        resets = [w['reset'] for w in self.parse_at(now).windows if w['reset'] > now]
        return datetime.datetime.fromtimestamp(min(resets)) if resets else None


class ClaudeCodeParser(LimitParser):
    source = 'code'

    def __init__(self, path=None):
        self.path = path or core.limits_path()

    def get_log_path(self):
        return self.path

    def parse_at(self, now):
        m = LimitMetrics('code', log_path=self.path)
        if not os.path.isdir(os.path.dirname(self.path)):
            m.status = 'NotFound'
            return m
        lim = core.read_limits(self.path, now)
        if not lim:
            return m
        m.updated = lim['updated']
        for wid in (core.FIVE, core.WEEK):
            w = lim.get(wid)
            if w:
                m.windows.append(make_window(wid, w['raw'], w['reset'], False, now))
        if m.windows:
            m.status = 'Ok'
        return m


class ClaudeDesktopParser(LimitParser):
    source = 'desktop'

    def __init__(self, custom_path=None):
        self.custom_path = custom_path or ''
        self.tables = {}
        self.journals = {}
        self.blobs = {}
        self.records = {}

    @staticmethod
    def data_roots():
        h = core.home()
        xdg = os.environ.get('XDG_CONFIG_HOME') or os.path.join(h, '.config')
        return [os.path.join(xdg, 'Claude'),
                os.path.join(h, '.var', 'app', 'com.anthropic.Claude', 'config', 'Claude')]

    @staticmethod
    def leveldb_dir(root):
        if not root:
            return ''
        nested = os.path.join(root, 'Local Storage', 'leveldb')
        if os.path.isdir(nested):
            return nested
        if os.path.isfile(os.path.join(root, 'CURRENT')):
            return root
        return ''

    def get_log_path(self):
        if self.custom_path:
            return self.leveldb_dir(self.custom_path)
        for root in self.data_roots():
            d = self.leveldb_dir(root)
            if d:
                return d
        return ''

    def parse_at(self, now):
        d = self.get_log_path()
        m = LimitMetrics('desktop', log_path=d)
        if not d:
            m.status = 'NotFound'
            return m
        best, seen = None, set()
        try:
            names = sorted(os.listdir(d))
        except OSError:
            names = []
        for name in names:
            path = os.path.join(d, name)
            if name.endswith('.log'):
                rec = self._scan_journal(path)
            elif name.endswith(('.ldb', '.sst')):
                rec = self._scan_table(path)
            else:
                continue
            seen.add(path)
            best = newest(best, [rec])
        idb = None
        for path in self._indexeddb_files(d):
            seen.add(path)
            idb = newest_windows(idb, self._scan_indexeddb(path))
        for cache in (self.tables, self.journals, self.blobs, self.records):
            for k in [k for k in cache if k not in seen]:
                del cache[k]
        five = max([r for r in (best, idb and idb['five']) if r], key=lambda r: r['observed_at'], default=None)
        week = idb and idb['week']
        if five:
            m.windows.append(make_window(core.FIVE, percent(five), int(five['resets_at']), True, now))
            times = set()
            for r in sorted((r for rs in self.records.values() for r in rs), key=lambda r: r['observed_at']):
                if r['resets_at'] == five['resets_at'] and 0 < r['observed_at'] <= now and r['observed_at'] not in times:
                    times.add(r['observed_at'])
                    m.samples.append({'t': r['observed_at'], 'f': percent(r), 'fr': int(r['resets_at'])})
        if week:
            m.windows.append(make_window(core.WEEK, percent(week), int(week['resets_at']), False, now))
        if not m.windows:
            return m
        m.updated = max(five['observed_at'] if five else 0, idb['observed_at'] if idb else 0)
        m.status = 'Ok'
        return m

    @staticmethod
    def _indexeddb_files(local_storage_dir):
        if not local_storage_dir.endswith(os.path.join('Local Storage', 'leveldb')):
            return []
        idb = os.path.join(os.path.dirname(os.path.dirname(local_storage_dir)), 'IndexedDB')
        out = []
        try:
            bases = sorted(b for b in os.listdir(idb) if b.startswith('https_claude.ai'))
        except OSError:
            return out
        for base in bases:
            for dp, _, names in os.walk(os.path.join(idb, base)):
                for name in sorted(names):
                    if base.endswith('.blob') or name.endswith(('.log', '.ldb')):
                        out.append(os.path.join(dp, name))
        return out

    def _scan_indexeddb(self, path):
        try:
            st = os.stat(path)
        except OSError:
            return None
        stamp = (st.st_size, st.st_mtime_ns)
        cached = self.blobs.get(path)
        if cached and cached['stamp'] == stamp:
            return cached['best']
        best = None
        try:
            if path.endswith('.ldb'):
                data = read_table_text(path).encode('latin-1')
            else:
                with open(path, 'rb') as f:
                    data = f.read()
                if data[:3] == b'\xff\x11\x02':
                    data = snappy(data[3:])
            for w in find_windows(data, st.st_mtime):
                best = newest_windows(best, w)
        except Exception:
            pass
        self.blobs[path] = {'stamp': stamp, 'best': best}
        return best

    def _scan_journal(self, path):
        j = self.journals.get(path)
        try:
            size = os.path.getsize(path)
        except OSError:
            return j and j['best']
        if not j or size < j['offset']:
            j = self.journals[path] = {'offset': 0, 'tail': '', 'best': None}
            self.records[path] = []
        if size == j['offset']:
            return j['best']
        try:
            with open(path, 'rb') as f:
                f.seek(j['offset'])
                data = f.read()
            text = j['tail'] + data.decode('latin-1')
            found = find_records(text)
            j['best'] = newest(j['best'], found)
            self.records[path] = (self.records.get(path, []) + found)[-500:]
            j['offset'] += len(data)
            j['tail'] = text[-JOURNAL_TAIL:]
        except OSError:
            pass
        return j['best']

    def _scan_table(self, path):
        try:
            st = os.stat(path)
        except OSError:
            return None
        stamp = (st.st_size, st.st_mtime_ns)
        cached = self.tables.get(path)
        if cached and cached['stamp'] == stamp:
            return cached['best']
        try:
            found = find_records(read_table_text(path))
        except Exception:
            found = []
        best = newest(None, found)
        self.records[path] = found[-500:]
        self.tables[path] = {'stamp': stamp, 'best': best}
        return best


def new_parser(source, path=None):
    if source == 'code':
        return ClaudeCodeParser(path)
    if source == 'desktop':
        return ClaudeDesktopParser(path)
    raise ValueError('unknown limit source: ' + source)


def find_records(text):
    out = []
    for match in RECORD_RE.finditer(text):
        s = match.group(0)
        reset, util = RESET_RE.search(s), UTIL_RE.search(s)
        if not (reset and util):
            continue
        observed = OBSERVED_RE.search(s)
        resets_at = float(reset.group(1))
        observed_at = float(observed.group(1)) if observed else 0.0
        out.append({'resets_at': resets_at / 1000 if resets_at > 1e11 else resets_at,
                    'utilization': max(0.0, float(util.group(1))),
                    'observed_at': observed_at / 1000 if observed_at > 1e11 else observed_at,
                    'at_wall': bool(AT_WALL_RE.search(s))})
    return out


def percent(r):
    if r['at_wall']:
        return 100.0
    u = r['utilization'] * 100 if r['utilization'] <= 1 else r['utilization']
    return round(u, 3)


def newest_windows(a, b):
    if a is None:
        return b
    if b is None:
        return a
    return b if b['observed_at'] >= a['observed_at'] else a


WINDOWS_KEY = b'"\x07windows'
UPDATED_KEY = b'"\x0ddataUpdatedAt'


def find_windows(data, fallback_time):
    """Ищет в V8-сериализованных данных объекты windows {"5h": {...}, "7d": {...}}."""
    out, i = [], 0
    while True:
        i = data.find(WINDOWS_KEY, i)
        if i < 0:
            return out
        p = i + len(WINDOWS_KEY)
        i = p
        try:
            obj, p = v8_read(data, p)
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue
        observed = fallback_time
        u = data.find(UPDATED_KEY, p)
        if 0 <= u - p < 4096 and data[u + len(UPDATED_KEY):u + len(UPDATED_KEY) + 1] == b'N':
            v = struct.unpack_from('<d', data, u + len(UPDATED_KEY) + 1)[0]
            if v > 0:
                observed = v / 1000 if v > 1e11 else v

        def record(key):
            w = obj.get(key)
            if not isinstance(w, dict) or not isinstance(w.get('resets_at'), float) or not isinstance(w.get('utilization'), float):
                return None
            reset = w['resets_at']
            return {'resets_at': reset / 1000 if reset > 1e11 else reset, 'utilization': max(0.0, w['utilization']),
                    'observed_at': observed, 'at_wall': w.get('status') == 'exceeded_limit'}

        five, week = record('5h'), record('7d')
        if five or week:
            out.append({'observed_at': observed, 'five': five, 'week': week})


def v8_read(b, p, depth=0):
    """Подмножество формата V8 structured clone: объекты, строки, числа, null, bool."""
    if depth > 16:
        raise ValueError('too deep')
    while p < len(b) and b[p] == 0:
        p += 1
    tag = b[p]
    p += 1
    if tag == 0x6f:
        obj = {}
        while True:
            while b[p] == 0:
                p += 1
            if b[p] == 0x7b:
                _, p = _varint(b, p + 1)
                return obj, p
            key, p = v8_read(b, p, depth + 1)
            value, p = v8_read(b, p, depth + 1)
            obj[str(key)] = value
    if tag in (0x22, 0x63):
        n, p = _varint(b, p)
        if p + n > len(b):
            raise ValueError('truncated v8 string')
        return b[p:p + n].decode('latin-1' if tag == 0x22 else 'utf-16-le'), p + n
    if tag == 0x4e:
        return struct.unpack_from('<d', b, p)[0], p + 8
    if tag == 0x49:
        z, p = _varint(b, p)
        return float((z >> 1) ^ -(z & 1)), p
    if tag == 0x55:
        v, p = _varint(b, p)
        return float(v), p
    if tag in (0x30, 0x5f):
        return None, p
    if tag in (0x54, 0x46):
        return tag == 0x54, p
    raise ValueError('unsupported v8 tag {0}'.format(tag))


def newest(current, records):
    best = current
    for r in records:
        if r is not None and (best is None or r['observed_at'] >= best['observed_at']):
            best = r
    return best


# ---------- LevelDB / Snappy ----------

def _varint(b, p):
    result = shift = 0
    while shift < 64:
        if p >= len(b):
            raise ValueError('truncated varint')
        c = b[p]
        p += 1
        result |= (c & 0x7f) << shift
        if not c & 0x80:
            return result, p
        shift += 7
    raise ValueError('bad varint')


def snappy(src):
    size, p = _varint(src, 0)
    if size > 256 * 1024 * 1024:
        raise ValueError('bad snappy length')
    dst = bytearray()
    while p < len(src):
        tag = src[p]
        p += 1
        kind = tag & 3
        if kind == 0:
            n = (tag >> 2) + 1
            if n > 60:
                extra = n - 60
                n = int.from_bytes(src[p:p + extra], 'little') + 1
                p += extra
            if p + n > len(src):
                raise ValueError('bad snappy literal')
            dst += src[p:p + n]
            p += n
            continue
        if kind == 1:
            n, off = ((tag >> 2) & 7) + 4, ((tag >> 5) << 8) | src[p]
            p += 1
        elif kind == 2:
            n, off = (tag >> 2) + 1, int.from_bytes(src[p:p + 2], 'little')
            p += 2
        else:
            n, off = (tag >> 2) + 1, int.from_bytes(src[p:p + 4], 'little')
            p += 4
        if off <= 0 or off > len(dst):
            raise ValueError('bad snappy copy')
        if off >= n:
            dst += dst[-off:len(dst) - off + n]
        else:
            for _ in range(n):
                dst.append(dst[-off])
    if len(dst) != size:
        raise ValueError('truncated snappy block')
    return bytes(dst)


def _block(f, offset, size):
    if offset + size + 5 > len(f):
        raise ValueError('bad block handle')
    raw, kind = f[offset:offset + size], f[offset + size]
    if kind == 0:
        return raw
    if kind == 1:
        return snappy(raw)
    raise ValueError('unknown block compression')


def read_table_text(path):
    with open(path, 'rb') as fh:
        f = fh.read()
    if len(f) < 48 or struct.unpack_from('<Q', f, len(f) - 8)[0] != TABLE_MAGIC:
        raise ValueError('not a LevelDB table')
    p = len(f) - 48
    _, p = _varint(f, p)
    _, p = _varint(f, p)
    index_offset, p = _varint(f, p)
    index_size, p = _varint(f, p)
    index = _block(f, index_offset, index_size)
    restarts = struct.unpack_from('<i', index, len(index) - 4)[0]
    limit, p, parts = len(index) - 4 - restarts * 4, 0, []
    while p < limit:
        _, p = _varint(index, p)
        key_len, p = _varint(index, p)
        value_len, p = _varint(index, p)
        p += key_len
        offset, q = _varint(index, p)
        size, _ = _varint(index, q)
        parts.append(_block(f, offset, size).decode('latin-1'))
        p += value_len
    return '\n'.join(parts)
