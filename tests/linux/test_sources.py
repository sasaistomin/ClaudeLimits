# Юнит-тесты парсеров (Claude Code / Claude Desktop на поддельных LevelDB-логах) и фонового опроса:
#   python3 tests/linux/test_sources.py
import datetime
import json
import os
import struct
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'linux'))
import claude_limits_core as core  # noqa: E402
import claude_limits_parsers as parsers  # noqa: E402
from claude_limits_monitor import LimitMonitoringService  # noqa: E402

NOW = 1_800_000_000


def record(util, reset, observed, at_wall=False):
    return ('{{"resetsAt":{0},"utilization":{1},"prevUtilization":0.1,"observedAt":{2},'
            '"atWall":{3},"fired":[],"shown":false}}').format(reset, util, observed, 'true' if at_wall else 'false')


def journal_entry(json_text):
    return (b'\x9a\x01\x00\x00\x01_https://claude.ai\x00\x01ochre.test\x8f\x01'
            + json_text.encode('latin-1') + b'\x00\x7b\xff')


def varint(v):
    out = bytearray()
    while True:
        b = v & 0x7f
        v >>= 7
        out.append(b | (0x80 if v else 0))
        if not v:
            return bytes(out)


def block(key, value):
    return varint(0) + varint(len(key)) + varint(len(value)) + key + value + struct.pack('<ii', 0, 1)


def snappy_literals(data):
    out = bytearray(varint(len(data)))
    for i in range(0, len(data), 60):
        chunk = data[i:i + 60]
        out.append((len(chunk) - 1) << 2)
        out += chunk
    return bytes(out)


def write_table(path, json_text, compress):
    data = block(b'_https://claude.ai\x00\x01ochre.test', b'\x01' + json_text.encode('latin-1'))
    body, kind = (snappy_literals(data), 1) if compress else (data, 0)
    f = bytearray(body) + bytes([kind]) + b'\0\0\0\0'
    index_offset = len(f)
    index = block(b'z', varint(0) + varint(len(body)))
    f += index + b'\0' + b'\0\0\0\0'
    footer = varint(index_offset) + varint(0) + varint(index_offset) + varint(len(index))
    f += footer.ljust(40, b'\0') + struct.pack('<Q', parsers.TABLE_MAGIC)
    with open(path, 'wb') as fh:
        fh.write(bytes(f))


def v8str(text):
    b = text.encode('latin-1')
    return b'"' + bytes([len(b)]) + b


def v8num(x):
    return b'N' + struct.pack('<d', x)


def v8window(util, reset, status='within_limit'):
    return (b'o' + v8str('status') + v8str(status) + v8str('resets_at') + v8num(reset)
            + v8str('utilization') + v8num(util) + v8str('surpassed_threshold') + b'0{\x04')


def idb_blob(five, week, updated_ms):
    """Кэш ответа claude.ai в IndexedDB: обёртка Chromium (ff 11 02) + Snappy + V8."""
    windows = b'o'
    if five:
        windows += v8str('5h') + v8window(*five)
    if week:
        windows += v8str('7d') + v8window(*week)
    windows += b'{\x02'
    v8 = (b'\xff\x15o' + v8str('messageLimits') + b'o' + v8str('type') + v8str('within_limit')
          + v8str('windows') + windows + b'{\x02{\x01' + b'"\x0ddataUpdatedAt' + v8num(updated_ms))
    return b'\xff\x11\x02' + snappy_literals(v8)


class FakeDesktop(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, 'Claude')
        self.db = os.path.join(self.root, 'Local Storage', 'leveldb')
        os.makedirs(self.db)
        with open(os.path.join(self.db, 'CURRENT'), 'w') as f:
            f.write('MANIFEST-000001\n')

    def tearDown(self):
        self.tmp.cleanup()

    def append(self, name, data):
        with open(os.path.join(self.db, name), 'ab') as f:
            f.write(data)

    def used(self, m):
        return round(m.windows[0]['used'], 6)


class TestSnappy(unittest.TestCase):
    def test_literals_and_overlapping_copy(self):
        self.assertEqual(parsers.snappy(bytes([0x0C, 0x0C]) + b'abcd' + bytes([0x11, 0x04])), b'abcdabcdabcd')
        self.assertEqual(parsers.snappy(bytes([6, 0x00]) + b'x' + bytes([0x12, 0x01, 0x00])), b'xxxxxx')

    def test_broken_stream(self):
        with self.assertRaises(Exception):
            parsers.snappy(bytes([0x0C, 0x11, 0x04]))


class TestDesktopParser(FakeDesktop):
    def test_not_installed(self):
        p = parsers.ClaudeDesktopParser(os.path.join(self.tmp.name, 'nope'))
        self.assertEqual(p.get_log_path(), '')
        self.assertFalse(p.is_installed())
        self.assertEqual(p.parse_at(NOW).status, 'NotFound')
        self.assertIsNone(p.get_reset_time())

    def test_paths_and_empty_db(self):
        p = parsers.ClaudeDesktopParser(self.root)
        self.assertTrue(p.is_installed())
        self.assertEqual(p.get_log_path(), self.db)
        self.assertEqual(parsers.ClaudeDesktopParser(self.db).get_log_path(), self.db)
        self.assertEqual(p.parse_at(NOW).status, 'NoData')

    def test_autodetect_xdg(self):
        old = {k: os.environ.get(k) for k in ('HOME', 'XDG_CONFIG_HOME')}
        try:
            os.environ['HOME'] = self.tmp.name
            os.environ['XDG_CONFIG_HOME'] = self.tmp.name
            self.assertEqual(parsers.ClaudeDesktopParser().get_log_path(), self.db)
        finally:
            for k, v in old.items():
                os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)

    def test_journal_newest_record(self):
        self.append('000003.log', journal_entry(record(0.35, NOW + 600, NOW - 7200)))
        self.append('000003.log', journal_entry(record(0.18, NOW + 3 * 3600, NOW - 60)))
        self.append('000003.log', journal_entry(record(0.9, NOW + 3 * 3600, NOW - 3600)))
        p = parsers.ClaudeDesktopParser(self.root)
        m = p.parse_at(NOW)
        self.assertEqual((m.status, m.source, m.log_path, len(m.windows)), ('Ok', 'desktop', self.db, 1))
        w = m.windows[0]
        self.assertEqual((w['id'], w['rolling'], round(w['used'], 6), round(w['left'], 6), w['reset']),
                         (core.FIVE, True, 18.0, 82.0, NOW + 3 * 3600))
        self.assertEqual(m.updated, NOW - 60)
        self.assertEqual(p.parse_at(NOW + 3 * 3600 + 1).windows[0]['used'], 0)
        self.assertIsInstance(p.get_reset_time(), (datetime.datetime, type(None)))

    def test_incremental_offset_split_record_and_garbage(self):
        log = os.path.join(self.db, '000005.log')
        self.append('000005.log', journal_entry(record(0.2, NOW + 3600, NOW - 300)))
        p = parsers.ClaudeDesktopParser(self.root)
        self.assertEqual(self.used(p.parse_at(NOW)), 20)
        offset = p.journals[log]['offset']
        self.assertEqual(offset, os.path.getsize(log))
        rec = record(0.55, NOW + 3600, NOW - 100).encode('latin-1')
        self.append('000005.log', rec[:40])
        self.assertEqual(self.used(p.parse_at(NOW)), 20)
        self.append('000005.log', rec[40:])
        self.assertEqual(self.used(p.parse_at(NOW)), 55)
        self.assertGreater(p.journals[log]['offset'], offset)
        self.append('000005.log', b'{"resetsAt":"x","utilization":}{"resetsAt":1,"observedAt":2}{{{\xff')
        self.append('000005.log', journal_entry(record(0.97, NOW + 1800, NOW - 10, at_wall=True)))
        w = p.parse_at(NOW).windows[0]
        self.assertEqual((w['used'], w['left'], w['reset']), (100.0, 0.0, NOW + 1800))
        with open(log, 'wb') as f:
            f.write(b'\1\2\3')
        self.assertEqual(p.parse_at(NOW).status, 'NoData')

    def test_tables_cache_and_compaction(self):
        write_table(os.path.join(self.db, '000010.ldb'), record(0.31, NOW + 7200, NOW - 900), True)
        self.assertIn('"utilization":0.31', parsers.read_table_text(os.path.join(self.db, '000010.ldb')))
        p = parsers.ClaudeDesktopParser(self.root)
        self.assertEqual(self.used(p.parse_at(NOW)), 31)
        self.assertIn(os.path.join(self.db, '000010.ldb'), p.tables)
        write_table(os.path.join(self.db, '000011.ldb'), record(0.6, NOW + 7200, NOW - 100), False)
        with open(os.path.join(self.db, '000012.ldb'), 'wb') as f:
            f.write(bytes(range(200)))
        self.append('000013.log', journal_entry(record(0.05, NOW + 7200, NOW - 5000)))
        self.assertEqual(self.used(p.parse_at(NOW)), 60)
        os.remove(os.path.join(self.db, '000011.ldb'))
        p.parse_at(NOW)
        self.assertNotIn(os.path.join(self.db, '000011.ldb'), p.tables)


class TestIndexedDB(FakeDesktop):
    def test_weekly_and_fresher_five_hour(self):
        blob_dir = os.path.join(self.root, 'IndexedDB', 'https_claude.ai_0.indexeddb.blob', '1', '00')
        os.makedirs(blob_dir)
        with open(os.path.join(blob_dir, '1d'), 'wb') as f:
            f.write(idb_blob((0.42, NOW + 3 * 3600), (0.08, NOW + 5 * 86400), (NOW - 30) * 1000))
        self.append('000003.log', journal_entry(record(0.3, NOW + 3 * 3600, NOW - 600)))
        p = parsers.ClaudeDesktopParser(self.root)
        m = p.parse_at(NOW)
        self.assertEqual((m.status, [w['id'] for w in m.windows]), ('Ok', [core.FIVE, core.WEEK]))
        self.assertEqual(m.window(core.FIVE)['used'], 42)
        week = m.window(core.WEEK)
        self.assertEqual((week['used'], week['left'], week['rolling'], week['reset']), (8, 92, False, NOW + 5 * 86400))
        self.assertEqual(m.updated, NOW - 30)
        self.append('000003.log', journal_entry(record(0.5, NOW + 3 * 3600, NOW - 5)))
        m = p.parse_at(NOW)
        self.assertEqual((m.window(core.FIVE)['used'], m.window(core.WEEK)['used']), (50, 8))
        self.assertEqual([s['f'] for s in m.samples], [30, 50])
        with open(os.path.join(blob_dir, '20'), 'wb') as f:
            f.write(b'\xff\x11\x02\x05\x01')
        self.assertEqual(len(p.parse_at(NOW).windows), 2)

        hist = os.path.join(self.tmp.name, 'desktop-history.jsonl')
        self.assertTrue(core.append_metrics_history(m, hist, NOW))
        self.assertEqual([(s['f'], s.get('w')) for s in core.read_history(hist)], [(30, None), (50, None), (50, 8)])
        self.assertFalse(core.append_metrics_history(m, hist, NOW))
        model = core.chart_model({core.FIVE: m.window(core.FIVE)}, core.read_history(hist), core.FIVE, NOW)
        self.assertEqual([u for _, u in model['points']], [0.0, 30.0, 50.0, 50.0])

    def test_v8_reader(self):
        obj, _ = parsers.v8_read(b'o' + v8str('a') + b'I\x06' + v8str('b') + b'T' + b'c\x04' + 'ок'.encode('utf-16-le') + b'_{\x03', 0)
        self.assertEqual(obj, {'a': 3.0, 'b': True, 'ок': None})
        with self.assertRaises(Exception):
            parsers.v8_read(b'o' + v8str('a') + b'Z', 0)


class TestCodeParser(unittest.TestCase):
    def test_wraps_limits_json(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, 'limits.json')
            p = parsers.ClaudeCodeParser(path)
            self.assertEqual(p.parse_at(NOW).status, 'NoData')
            self.assertEqual(parsers.ClaudeCodeParser(os.path.join(d, 'no', 'limits.json')).parse_at(NOW).status, 'NotFound')
            with open(path, 'w') as f:
                json.dump({'updated_at': NOW, 'rate_limits': {
                    'five_hour': {'used_percentage': 23.5, 'resets_at': NOW + 3600},
                    'seven_day': {'used_percentage': 90, 'resets_at': NOW - 10}}}, f)
            m = p.parse_at(NOW)
            self.assertEqual((m.status, m.updated), ('Ok', NOW))
            self.assertEqual((m.window(core.FIVE)['left'], m.window(core.FIVE)['rolling']), (76.5, False))
            self.assertEqual((m.window(core.WEEK)['used'], m.window(core.WEEK)['raw']), (0.0, 90.0))

    def test_contract(self):
        for s in core.SOURCES:
            p = parsers.new_parser(s, '/nonexistent/x')
            self.assertIsInstance(p, parsers.LimitParser)
            self.assertEqual(p.source, s)
            for name in ('parse_limits', 'get_reset_time', 'is_installed', 'get_log_path'):
                self.assertTrue(callable(getattr(p, name)))
        with self.assertRaises(ValueError):
            parsers.new_parser('web')


class TestMonitoring(FakeDesktop):
    def test_threads_subscription_and_debounced_updates(self):
        code = os.path.join(self.tmp.name, 'limits.json')

        def write(u):
            with open(code + '.tmp', 'w') as f:
                json.dump({'updated_at': time.time(), 'rate_limits': {
                    'five_hour': {'used_percentage': u, 'resets_at': time.time() + 3600}}}, f)
            os.replace(code + '.tmp', code)

        write(10)
        self.append('000003.log', journal_entry(record(0.25, int(time.time()) + 3600, time.time())))
        svc = LimitMonitoringService(interval=1.5, debounce=0.2)
        got = []
        svc.subscribe('code', got.append)
        try:
            svc.watch('code', code)
            svc.watch('desktop', self.root)
            self.assertTrue(svc.wait_for_all(15))
            self.assertEqual(svc.latest['code'].window(core.FIVE)['used'], 10)
            self.assertAlmostEqual(svc.latest['desktop'].window(core.FIVE)['used'], 25)
            self.assertEqual(len(got), 1)
            for u in (30, 40, 64):
                write(u)
                time.sleep(0.05)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and svc.latest['code'].window(core.FIVE)['used'] != 64:
                svc.dispatch()
                time.sleep(0.05)
            self.assertEqual(svc.latest['code'].window(core.FIVE)['used'], 64)
            self.assertLessEqual(len(got), 3, 'debounce: серия записей не даёт событие на каждую')
            svc.watch('desktop', os.path.join(self.tmp.name, 'missing'))
            self.assertTrue(svc.wait_for_all(10))
            self.assertEqual(svc.latest['desktop'].status, 'NotFound')
        finally:
            workers = list(svc.workers.values())
            svc.close()
        self.assertTrue(all(not w.is_alive() for w in workers))
        self.assertEqual(svc.workers, {})


if __name__ == '__main__':
    r = unittest.main(exit=False, verbosity=0).result
    if r.wasSuccessful():
        print('✅ Linux sources: все тесты прошли ({0})'.format(r.testsRun))
    sys.exit(0 if r.wasSuccessful() else 1)
