# Юнит-тесты логики Linux-версии:  python3 tests/linux/test_core.py
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'linux'))
import claude_limits_core as core  # noqa: E402

RU, EN = core.STRINGS['ru'], core.STRINGS['en']
NOW = 1_800_000_000


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def win(raw, reset, now=NOW):
    used = 0.0 if reset < now else raw
    return {'used': used, 'raw': raw, 'left': max(0, 100 - used), 'reset': reset}


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.old = {k: os.environ.get(k) for k in ('HOME', 'XDG_CONFIG_HOME')}
        os.environ['HOME'] = self.dir.name
        os.environ.pop('XDG_CONFIG_HOME', None)

    def tearDown(self):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.dir.cleanup()


class TestStrings(unittest.TestCase):
    def test_same_keys(self):
        self.assertEqual(set(RU), set(EN))

    def test_countdown(self):
        self.assertEqual(core.format_countdown(NOW + 2 * 86400 + 3 * 3600, RU, NOW), 'через 2 д 3 ч')
        self.assertEqual(core.format_countdown(NOW + 3 * 3600 + 5 * 60, EN, NOW), 'in 3h 5m')
        self.assertEqual(core.format_countdown(NOW + 59, RU, NOW), 'через 0 мин')
        self.assertEqual(core.format_countdown(NOW - 1, EN, NOW), 'done')

    def test_ago(self):
        self.assertEqual(core.format_ago(NOW - 10, RU, NOW), 'только что')
        self.assertEqual(core.format_ago(NOW - 300, EN, NOW), '5 min ago')
        self.assertEqual(core.format_ago(NOW - 7200, RU, NOW), '2 ч назад')
        self.assertEqual(core.format_ago(NOW - 3 * 86400, EN, NOW), '3 d ago')

    def test_lang(self):
        self.assertEqual(core.resolve_lang('ru', {}), 'ru')
        self.assertEqual(core.resolve_lang('en', {'LANG': 'ru_RU.UTF-8'}), 'en')
        self.assertEqual(core.resolve_lang('system', {'LANG': 'ru_RU.UTF-8'}), 'ru')
        self.assertEqual(core.resolve_lang('system', {'LANG': 'de_DE.UTF-8'}), 'en')
        self.assertEqual(core.resolve_lang('system', {'LC_ALL': 'ru_RU', 'LANG': 'en_US'}), 'ru')
        self.assertEqual(core.resolve_lang('system', {}), 'en')

    def test_level_and_label(self):
        self.assertEqual([core.level(u) for u in (0, 69.9, 70, 89, 90, 100)],
                         ['green', 'green', 'yellow', 'yellow', 'red', 'red'])
        self.assertEqual(core.indicator_label(None), '—')
        self.assertEqual(core.indicator_label({core.FIVE: win(42.4, NOW + 60), core.WEEK: None}), '58%')
        self.assertEqual(core.indicator_label({core.FIVE: None, core.WEEK: win(10, NOW + 60)}), '90%')


class TestLimits(Sandbox):
    def write(self, obj):
        os.makedirs(core.claude_dir(), exist_ok=True)
        with open(core.limits_path(), 'w', encoding='utf-8') as f:
            f.write(obj if isinstance(obj, str) else json.dumps(obj))

    def test_read(self):
        self.write({'updated_at': NOW, 'rate_limits': {'five_hour': {'used_percentage': 30, 'resets_at': NOW + 100},
                                                       'seven_day': {'used_percentage': 50, 'resets_at': NOW - 1}}})
        l = core.read_limits(now=NOW)
        self.assertEqual(l[core.FIVE]['left'], 70)
        self.assertEqual(l[core.WEEK]['used'], 0)      # сброс прошёл
        self.assertEqual(l[core.WEEK]['raw'], 50)

    def test_bad(self):
        self.assertIsNone(core.read_limits(now=NOW))
        self.write('{broken')
        self.assertIsNone(core.read_limits(now=NOW))
        self.write({'model': 'x'})
        self.assertIsNone(core.read_limits(now=NOW))


class TestNotify(unittest.TestCase):
    def test_thresholds_once_per_window(self):
        n = {}
        self.assertIsNone(core.notify_event('f', win(79, NOW + 100), n, NOW))
        ev = core.notify_event('f', win(81, NOW + 100), n, NOW)
        self.assertEqual((ev['type'], ev['threshold'], ev['used']), ('low', 80, 81))
        self.assertIsNone(core.notify_event('f', win(85, NOW + 100), n, NOW))
        self.assertEqual(core.notify_event('f', win(96, NOW + 100), n, NOW)['threshold'], 95)
        self.assertIsNone(core.notify_event('f', win(99, NOW + 100), n, NOW))

    def test_jump_to_96_marks_80(self):
        n = {}
        self.assertEqual(core.notify_event('f', win(96, NOW + 100), n, NOW)['threshold'], 95)
        self.assertIsNone(core.notify_event('f', win(97, NOW + 100), n, NOW))
        self.assertIn('f:80', n)

    def test_new_window_and_drift(self):
        n = {}
        core.notify_event('f', win(81, NOW + 100), n, NOW)
        self.assertIsNone(core.notify_event('f', win(82, NOW + 100 + 60), n, NOW))       # дрожание resets_at
        self.assertIsNotNone(core.notify_event('f', win(81, NOW + 100 + 18000), n, NOW))  # новое окно

    def test_reset(self):
        n = {}
        self.assertEqual(core.notify_event('f', win(85, NOW - 60), n, NOW), {'type': 'reset'})
        self.assertIsNone(core.notify_event('f', win(85, NOW - 60), n, NOW))
        self.assertIsNone(core.notify_event('g', win(50, NOW - 60), {}, NOW))     # мало использовали
        self.assertIsNone(core.notify_event('g', win(90, NOW - 1000), {}, NOW))   # давно сбросился

    def test_format(self):
        title, body, urg = core.format_notification({'type': 'low', 'threshold': 95, 'used': 96},
                                                    win(96, NOW + 3600), True, RU, NOW)
        self.assertEqual(title, 'Claude: осталось 4%')
        self.assertEqual(body, '5-часовое окно израсходовано на 96%. Сброс через 1 ч 0 мин.')
        self.assertEqual(urg, 'critical')
        self.assertEqual(core.format_notification({'type': 'reset'}, win(90, NOW), False, EN, NOW)[0],
                         'Claude limit has reset')


class TestChart(unittest.TestCase):
    def test_points_and_forecast(self):
        reset = NOW + 3 * 3600                      # прошло 2 ч из 5
        lim = {core.FIVE: win(40, reset), core.WEEK: None}
        hist = [{'t': NOW - 3600, 'f': 20}, {'t': NOW - 99999, 'f': 5}, {'t': NOW - 1800, 'w': 3}]
        m = core.chart_model(lim, hist, core.FIVE, NOW)
        self.assertEqual(m['points'], [(reset - 18000, 0.0), (NOW - 3600, 20.0), (NOW, 40.0)])
        self.assertAlmostEqual(m['rate'], 40 / 7200)
        self.assertIsNone(m['run_out'])   # 60% за 3 ч при таком темпе — ровно к сбросу, т.е. хватит
        self.assertIsNone(core.chart_model(lim, hist, core.WEEK, NOW))

    def test_runs_out_before_reset(self):
        lim = {core.FIVE: win(80, NOW + 3 * 3600)}
        m = core.chart_model(lim, [], core.FIVE, NOW)
        self.assertLess(m['run_out'], NOW + 3 * 3600)
        self.assertTrue(core.forecast_text(m, RU).startswith('Прогноз: при таком темпе лимит закончится в '))

    def test_no_forecast(self):
        lim = {core.WEEK: win(1, NOW + 7 * 86400 - 100)}       # окно только началось
        m = core.chart_model(lim, [], core.WEEK, NOW)
        self.assertEqual(m['rate'], 0)
        self.assertEqual(core.forecast_text(m, EN), 'Forecast: at this pace the limit will last until reset')
        self.assertEqual(core.forecast_text(None, RU), RU['chart_no_data'])


class TestStatusline(Sandbox):
    def payload(self, f, w, model='Opus'):
        return json.dumps({'model': {'display_name': model}, 'rate_limits': {
            'five_hour': {'used_percentage': f, 'resets_at': NOW + 3600},
            'seven_day': {'used_percentage': w, 'resets_at': NOW + 86400}}})

    def test_output_and_files(self):
        self.assertEqual(core.statusline(self.payload(23.5, 41), NOW), '[Opus] 5h: 24% 7d: 41%')
        with open(core.limits_path(), encoding='utf-8') as f:
            self.assertEqual(json.load(f)['rate_limits']['five_hour']['used_percentage'], 23.5)
        core.statusline(self.payload(23.5, 41), NOW + 5)
        core.statusline(self.payload(30, 41), NOW + 10)
        self.assertEqual([s['f'] for s in core.read_history()], [23.5, 30])

    def test_edge_inputs(self):
        self.assertEqual(core.statusline('не json'), '[Claude]')
        self.assertEqual(core.statusline(''), '[Claude]')
        self.assertEqual(core.statusline('[1,2]'), '[Claude]')
        self.assertEqual(core.statusline('{"model":{"display_name":"Модель"}}'), '[Модель]')
        self.assertFalse(os.path.exists(core.limits_path()))
        self.assertEqual(core.statusline('{"rate_limits":{"seven_day":{"used_percentage":5,"resets_at":1}}}'), '[Claude] 7d: 5%')

    def test_prune(self):
        os.makedirs(core.claude_dir(), exist_ok=True)
        with open(core.history_path(), 'w') as f:
            for _ in range(20000):   # > 512 КБ
                f.write('{"t":%d,"f":1,"w":1}\n' % (NOW - 20 * 86400))
        core.statusline(self.payload(70, 80), NOW)
        self.assertEqual([s['f'] for s in core.read_history()], [70])


class TestSettings(Sandbox):
    def test_install_merge_and_backup(self):
        os.makedirs(core.claude_dir())
        with open(core.settings_path(), 'w') as f:
            json.dump({'model': 'opus', 'statusLine': {'type': 'command', 'command': '~/mine.sh'}}, f)
        ok, replaced = core.set_statusline(core.statusline_command('/x/claude-limits'))
        self.assertEqual((ok, replaced), (True, '~/mine.sh'))
        s = json.loads(read(core.settings_path()))
        self.assertEqual(s['model'], 'opus')
        self.assertEqual(s['statusLine']['command'], 'python3 "/x/claude-limits/statusline.py"')
        self.assertEqual(json.loads(read(core.settings_path() + '.bak'))['statusLine']['command'], '~/mine.sh')
        self.assertEqual(core.set_statusline(core.statusline_command('/x/claude-limits')), (True, None))  # повторно
        self.assertTrue(core.remove_statusline())
        s = json.loads(read(core.settings_path()))
        self.assertNotIn('statusLine', s)
        self.assertEqual(s['model'], 'opus')

    def test_broken_and_missing(self):
        self.assertEqual(core.set_statusline('cmd claude-limits'), (True, None))   # файла не было
        with open(core.settings_path(), 'w') as f:
            f.write('{сломано')
        self.assertEqual(core.set_statusline('cmd'), (False, None))
        self.assertEqual(read(core.settings_path()), '{сломано')
        self.assertFalse(core.remove_statusline())

    def test_foreign_not_removed(self):
        os.makedirs(core.claude_dir())
        with open(core.settings_path(), 'w') as f:
            json.dump({'statusLine': {'type': 'command', 'command': '~/mine.sh'}}, f)
        self.assertFalse(core.remove_statusline())

    def test_config_and_autostart(self):
        cfg = core.read_config()
        self.assertEqual(cfg, {'language': 'system', 'notifications': True, 'notified': {}})
        cfg.update(language='ru', notifications=False, notified={'five_hour:80': 123})
        core.save_config(cfg)
        self.assertEqual(core.read_config(), cfg)
        core.set_autostart(True, '/a b/claude_limits.py')
        self.assertTrue(core.autostart_enabled())
        self.assertIn('Exec=python3 "/a b/claude_limits.py"', read(core.autostart_path()))
        core.set_autostart(False, '')
        self.assertFalse(core.autostart_enabled())


if __name__ == '__main__':
    r = unittest.main(exit=False, verbosity=0).result
    n = r.testsRun
    if r.wasSuccessful():
        print('✅ Linux unit: все тесты прошли ({0})'.format(n))
    sys.exit(0 if r.wasSuccessful() else 1)
