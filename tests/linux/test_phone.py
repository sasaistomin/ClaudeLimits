# Тесты выгрузки для виджета на телефоне (linux/claude_limits_phone.py):  python3 tests/linux/test_phone.py
# GitHub подменяется локальным HTTP-сервером (CLAUDE_LIMITS_GITHUB_API).
import io
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'linux'))
import claude_limits_phone as phone  # noqa: E402
from claude_limits_parsers import LimitMetrics, make_window  # noqa: E402

NOW = 1_800_000_000
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'scriptable', 'payload.json')


def metrics():
    code = LimitMetrics('code', 'Ok', NOW - 100, '', [make_window('five_hour', 42.5, NOW + 10000, False, NOW),
                                                      make_window('seven_day', 13, NOW + 300000, False, NOW)])
    desktop = LimitMetrics('desktop', 'Ok', NOW - 10000, '', [make_window('five_hour', 80, NOW + 5000, True, NOW),
                                                              make_window('seven_day', 20, NOW + 300000, False, NOW)])
    return {'code': code, 'desktop': desktop}


class FakeGitHub(BaseHTTPRequestHandler):
    gists = {}
    calls = []
    token = 'good'

    def log_message(self, *a):
        pass

    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}')
        FakeGitHub.calls.append((self.command, self.path, self.headers.get('Authorization'), body))
        if self.headers.get('Authorization') != 'Bearer ' + FakeGitHub.token:
            return self._reply(401, {'message': 'Bad credentials'})
        if self.command == 'POST' and self.path == '/gists':
            gid = 'g{0}'.format(len(FakeGitHub.gists) + 1)
            FakeGitHub.gists[gid] = body
            return self._reply(201, {'id': gid})
        gid = self.path.rsplit('/', 1)[-1]
        if self.command == 'PATCH' and gid in FakeGitHub.gists:
            FakeGitHub.gists[gid] = body
            return self._reply(200, {'id': gid})
        return self._reply(404, {'message': 'Not Found'})

    do_POST = do_PATCH = _handle


class Sandbox(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(('127.0.0.1', 0), FakeGitHub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.old = {k: os.environ.get(k) for k in ('HOME', 'CLAUDE_LIMITS_GITHUB_API', 'CLAUDE_LIMITS_GITHUB_TOKEN')}
        os.environ['HOME'] = self.dir.name
        os.environ['CLAUDE_LIMITS_GITHUB_API'] = 'http://127.0.0.1:{0}/'.format(self.server.server_port)
        os.environ.pop('CLAUDE_LIMITS_GITHUB_TOKEN', None)
        FakeGitHub.gists, FakeGitHub.calls, FakeGitHub.token = {}, [], 'good'

    def tearDown(self):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.dir.cleanup()

    def quiet(self, fn, *a):
        out = io.StringIO()
        with redirect_stdout(out):
            rc = fn(*a)
        return rc, out.getvalue()


class PayloadTests(unittest.TestCase):
    def test_payload_matches_widget_fixture(self):
        with open(FIXTURE, encoding='utf-8') as f:
            self.assertEqual(phone.payload(metrics(), NOW), json.load(f))

    def test_payload_skips_sources_without_data_and_keeps_raw_percent(self):
        m = metrics()
        m['desktop'] = LimitMetrics('desktop', 'NotFound')
        m['code'].windows[0] = make_window('five_hour', 90, NOW - 1, False, NOW)
        p = phone.payload(m, NOW)
        self.assertEqual(list(p['sources']), ['code'])
        self.assertEqual(p['sources']['code']['windows'][0]['used'], 90)
        self.assertEqual(phone.payload({}, NOW)['sources'], {})

    def test_key_ignores_send_time(self):
        self.assertEqual(phone.payload_key(phone.payload(metrics(), NOW)), phone.payload_key(phone.payload(metrics(), NOW + 99)))

    def test_should_send(self):
        self.assertTrue(phone.should_send('a', None, 0, 0, NOW))
        self.assertFalse(phone.should_send('a', 'a', 0, 0, NOW))
        self.assertFalse(phone.should_send('b', 'a', NOW - 59, 0, NOW))
        self.assertTrue(phone.should_send('b', 'a', NOW - 60, 0, NOW))
        self.assertFalse(phone.should_send('b', 'a', 0, NOW - 299, NOW))
        self.assertTrue(phone.should_send('b', 'a', 0, NOW - 300, NOW))


class ConfigAndSyncTests(Sandbox):
    def test_config_roundtrip_private(self):
        self.assertIsNone(phone.read_phone_config())
        phone.save_phone_config('tok', 'gid')
        self.assertEqual(phone.read_phone_config(), {'token': 'tok', 'gist_id': 'gid'})
        self.assertEqual(stat.S_IMODE(os.stat(phone.config_path()).st_mode), 0o600)
        with open(phone.config_path(), 'w') as f:
            f.write('{"token": ""}')
        self.assertIsNone(phone.read_phone_config())

    def test_sync_sends_once_per_change_and_throttles(self):
        sent, clock = [], [NOW]
        sync = phone.PhoneSync(send=lambda t, g, p: sent.append((t, g, p)), clock=lambda: clock[0])
        sync.offer(metrics())
        self.assertFalse(sync.tick(background=False), 'без настроек ничего не отправляется')
        phone.save_phone_config('tok', 'gid')
        self.assertTrue(sync.tick(background=False))
        self.assertEqual(sent[0][:2], ('tok', 'gid'))
        self.assertIn('code', sent[0][2]['sources'])
        clock[0] += 120
        self.assertFalse(sync.tick(background=False), 'те же цифры — не отправляем')
        m = metrics()
        m['code'].windows[0] = make_window('five_hour', 50, NOW + 10000, False, NOW)
        sync.offer(m)
        clock[0] += 10
        self.assertTrue(sync.tick(background=False))
        m2 = metrics()
        m2['code'].windows[0] = make_window('five_hour', 60, NOW + 10000, False, NOW)
        sync.offer(m2)
        clock[0] += 10
        self.assertFalse(sync.tick(background=False), 'не чаще раза в минуту')
        clock[0] += 60
        self.assertTrue(sync.tick(background=False))
        self.assertEqual(len(sent), 3)

    def test_sync_backs_off_after_error_and_reloads_config(self):
        clock = [NOW]
        calls = []

        def boom(t, g, p):
            calls.append(g)
            raise OSError('down')
        sync = phone.PhoneSync(send=boom, clock=lambda: clock[0])
        phone.save_phone_config('tok', 'gid')
        sync.offer(metrics())
        self.assertTrue(sync.tick(background=False))
        self.assertEqual(sync.error, 'down')
        clock[0] += 100
        self.assertFalse(sync.tick(background=False), 'после ошибки ждём 5 минут')
        clock[0] += 200
        self.assertTrue(sync.tick(background=False))
        os.remove(phone.config_path())
        clock[0] += 400
        self.assertFalse(sync.tick(background=False), 'настройки удалены — выгрузка выключена')
        self.assertFalse(sync.enabled)

    def test_sync_against_fake_github(self):
        phone.save_phone_config('good', 'g1')
        FakeGitHub.gists['g1'] = {}
        sync = phone.PhoneSync(clock=lambda: NOW)
        sync.offer(metrics())
        self.assertTrue(sync.tick(background=False))
        self.assertIsNone(sync.error)
        content = json.loads(FakeGitHub.gists['g1']['files']['claude-limits.json']['content'])
        self.assertEqual(content['sources']['code']['windows'][0]['used'], 42.5)


class SetupTests(Sandbox):
    def test_setup_creates_secret_gist_and_saves_config(self):
        rc, out = self.quiet(phone.setup, 'good')
        self.assertEqual(rc, 0, out)
        method, path, auth, body = FakeGitHub.calls[0]
        self.assertEqual((method, path, auth), ('POST', '/gists', 'Bearer good'))
        self.assertIs(body['public'], False)
        self.assertIn('claude-limits.json', body['files'])
        self.assertEqual(phone.read_phone_config(), {'token': 'good', 'gist_id': 'g1'})
        self.assertIn('g1', out)

    def test_setup_again_reuses_gist_and_recreates_deleted(self):
        self.quiet(phone.setup, 'good')
        rc, out = self.quiet(phone.setup, 'good')
        self.assertEqual((rc, FakeGitHub.calls[-1][0]), (0, 'PATCH'))
        self.assertEqual(len(FakeGitHub.gists), 1)
        FakeGitHub.gists.clear()
        rc, out = self.quiet(phone.setup, 'good')
        self.assertEqual(rc, 0, out)
        self.assertEqual(FakeGitHub.calls[-1][0], 'POST')
        self.assertEqual(phone.read_phone_config()['gist_id'], 'g1')

    def test_setup_bad_token_keeps_old_config(self):
        phone.save_phone_config('old', 'g9')
        rc, out = self.quiet(phone.setup, 'bad')
        self.assertEqual(rc, 1)
        self.assertIn('401', out)
        self.assertEqual(phone.read_phone_config(), {'token': 'old', 'gist_id': 'g9'})

    def test_setup_token_from_env_and_empty(self):
        os.environ['CLAUDE_LIMITS_GITHUB_TOKEN'] = ' good \n'
        self.assertEqual(self.quiet(phone.setup)[0], 0)
        os.environ['CLAUDE_LIMITS_GITHUB_TOKEN'] = ''
        real, phone.getpass.getpass = phone.getpass.getpass, lambda prompt='': ''
        try:
            self.assertEqual(self.quiet(phone.setup)[0], 1)
        finally:
            phone.getpass.getpass = real

    def test_disable_and_status(self):
        self.assertIn('Не настроено', self.quiet(phone.status)[1])
        phone.save_phone_config('good', 'g5')
        self.assertIn('g5', self.quiet(phone.status)[1])
        self.assertIn('выключена', self.quiet(phone.disable)[1])
        self.assertFalse(os.path.exists(phone.config_path()))
        self.assertIn('не настроена', self.quiet(phone.disable)[1])


if __name__ == '__main__':
    unittest.main(verbosity=1)
