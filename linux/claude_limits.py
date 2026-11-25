#!/usr/bin/env python3
# ClaudeLimits for Linux — значок в трее (GTK3 + AyatanaAppIndicator/AppIndicator, запасной вариант — Gtk.StatusIcon).
# Вкладки «Claude Code» / «Claude Desktop»; данные приходят от LimitMonitoringService (фоновые потоки).
# Нужны пакеты: python3-gi, gir1.2-ayatanaappindicator3-0.1 (или аналог), libnotify-bin — их ставит install.sh.
# CLAUDE_LIMITS_SELFTEST=1 — автотест: собрать интерфейс, прогнать языки и график, выйти.
import fcntl
import importlib
import os
import shutil
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import claude_limits_core as core  # noqa: E402
from claude_limits_monitor import LimitMonitoringService  # noqa: E402
from claude_limits_phone import PhoneSync  # noqa: E402

import gi  # noqa: E402
gi.require_version('Gtk', '3.0')
from gi.repository import Gdk, GLib, Gtk  # noqa: E402
import cairo  # noqa: E402

AppIndicator = None
for _name in ('AyatanaAppIndicator3', 'AppIndicator3'):
    try:
        gi.require_version(_name, '0.1')
        AppIndicator = importlib.import_module('gi.repository.' + _name)
        break
    except (ValueError, ImportError):
        pass

SELFTEST = bool(os.environ.get('CLAUDE_LIMITS_SELFTEST'))
APP_PATH = os.path.abspath(__file__)
COLORS = {'green': (0.20, 0.66, 0.33), 'yellow': (0.93, 0.66, 0.10), 'red': (0.86, 0.22, 0.20), 'none': (0.55, 0.55, 0.55)}


# ---------- значок ----------

def icon_dir():
    base = os.environ.get('XDG_CACHE_HOME') or os.path.join(core.home(), '.cache')
    d = os.path.join(base, 'claude-limits', 'icons')
    os.makedirs(d, exist_ok=True)
    return d

def make_icon(lvl, used):
    """Кольцо: серая дорожка + цветная дуга по израсходованной доле. Имя файла = имя иконки."""
    step = 0 if used is None else int(round(min(100, max(0, used)) / 5) * 5)
    name = 'claude-limits-{0}-{1}'.format(lvl, step)
    path = os.path.join(icon_dir(), name + '.png')
    if not os.path.exists(path):
        size = 64
        s = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
        cr = cairo.Context(s)
        c, r = size / 2, size / 2 - 7
        cr.set_line_width(10)
        cr.set_source_rgba(0.6, 0.6, 0.6, 0.45)
        cr.arc(c, c, r, 0, 6.2832)
        cr.stroke()
        cr.set_source_rgb(*COLORS[lvl])
        if step > 0:
            cr.arc(c, c, r, -1.5708, -1.5708 + 6.2832 * step / 100)
            cr.stroke()
        cr.arc(c, c, 7, 0, 6.2832)
        cr.fill()
        s.write_to_png(path)
    return name, path


# ---------- график (общий для окна и автотеста) ----------

def value_at(points, x):
    v = 0.0
    for t, u in points:
        if t <= x:
            v = u
        else:
            break
    return v

def draw_chart(cr, w, h, model, t, hover_x=None):
    L, R, T, B = 38, 14, 10, 26
    pw, ph = w - L - R, h - T - B
    cr.set_source_rgb(1, 1, 1)
    cr.paint()
    cr.select_font_face('Sans', cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
    cr.set_font_size(10)
    if not model:
        cr.set_source_rgb(0.4, 0.4, 0.4)
        cr.move_to(L, T + ph / 2)
        cr.show_text(t['chart_no_data'])
        return
    start, end = model['start'], model['end']
    X = lambda ts: L + (ts - start) / (end - start) * pw  # noqa: E731
    Y = lambda u: T + ph - min(110, u) / 100 * ph         # noqa: E731
    # сетка и подписи процентов
    for u in (0, 25, 50, 75, 100):
        cr.set_source_rgb(0.9, 0.9, 0.9)
        cr.set_line_width(1)
        cr.move_to(L, Y(u)); cr.line_to(L + pw, Y(u)); cr.stroke()
        cr.set_source_rgb(0.45, 0.45, 0.45)
        cr.move_to(4, Y(u) + 3); cr.show_text('{0}%'.format(u))
    # граница 100%
    cr.set_source_rgba(0.86, 0.22, 0.20, 0.8)
    cr.set_line_width(1.5)
    cr.move_to(L, Y(100)); cr.line_to(L + pw, Y(100)); cr.stroke()
    # подписи времени
    week = model['kind'] == core.WEEK
    step = 86400 if week else 3600
    cr.set_source_rgb(0.45, 0.45, 0.45)
    tick = start
    while tick <= end + 1:
        lt = time.localtime(tick)
        label = t['days'][lt.tm_wday] if week else time.strftime('%H:%M', lt)
        cr.move_to(X(tick) - 12, T + ph + 16); cr.show_text(label)
        tick += step
    # ступенчатая линия + заливка
    pts = model['points']
    col = COLORS[core.level(model['used'])]
    cr.move_to(X(pts[0][0]), Y(pts[0][1]))
    for (t0, u0), (t1, u1) in zip(pts, pts[1:]):
        cr.line_to(X(t1), Y(u0))
        cr.line_to(X(t1), Y(u1))
    path = cr.copy_path()
    cr.line_to(X(pts[-1][0]), Y(0)); cr.line_to(X(pts[0][0]), Y(0)); cr.close_path()
    cr.set_source_rgba(col[0], col[1], col[2], 0.18)
    cr.fill()
    cr.append_path(path)
    cr.set_source_rgb(*col)
    cr.set_line_width(2)
    cr.stroke()
    # прогноз
    now, used, rate = model['now'], model['used'], model['rate']
    if rate > 0:
        tend = model['run_out'] or end
        cr.set_dash([5, 4])
        cr.set_source_rgba(col[0], col[1], col[2], 0.8)
        cr.move_to(X(now), Y(used)); cr.line_to(X(tend), Y(used + rate * (tend - now))); cr.stroke()
        cr.set_dash([])
    cr.set_source_rgb(*col)
    cr.arc(X(now), Y(used), 4, 0, 6.2832); cr.fill()
    # наведение
    if hover_x is not None and L <= hover_x <= L + pw:
        ts = start + (hover_x - L) / pw * (end - start)
        if ts <= now:
            v = value_at(pts, ts)
            cr.set_source_rgba(0, 0, 0, 0.35); cr.set_line_width(1)
            cr.move_to(hover_x, T); cr.line_to(hover_x, T + ph); cr.stroke()
            lt = time.localtime(ts)
            txt = '{0}{1} — {2}%'.format((t['days'][lt.tm_wday] + ' ') if week else '', time.strftime('%H:%M', lt), int(round(v)))
            ext = cr.text_extents(txt)
            tx = min(hover_x + 6, L + pw - ext.width - 6)
            cr.set_source_rgba(1, 1, 1, 0.9); cr.rectangle(tx - 3, T + 2, ext.width + 6, 16); cr.fill()
            cr.set_source_rgb(0.1, 0.1, 0.1); cr.move_to(tx, T + 14); cr.show_text(txt)


class ChartWindow(Gtk.Window):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.kind = core.FIVE
        self.hover = None
        self.set_default_size(560, 330)
        self.set_position(Gtk.WindowPosition.MOUSE)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_border_width(10)
        self.add(box)
        row = Gtk.Box(spacing=0)
        row.get_style_context().add_class('linked')
        self.b5 = Gtk.RadioButton.new_with_label(None, '')
        self.bw = Gtk.RadioButton.new_with_label_from_widget(self.b5, '')
        for b, k in ((self.b5, core.FIVE), (self.bw, core.WEEK)):
            b.set_mode(False)
            b.connect('toggled', self.on_kind, k)
            row.pack_start(b, False, False, 0)
        box.pack_start(row, False, False, 0)
        self.area = Gtk.DrawingArea()
        self.area.set_size_request(520, 240)
        self.area.add_events(Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.area.connect('draw', self.on_draw)
        self.area.connect('motion-notify-event', self.on_motion)
        self.area.connect('leave-notify-event', self.on_leave)
        box.pack_start(self.area, True, True, 0)
        self.forecast = Gtk.Label(xalign=0)
        box.pack_start(self.forecast, False, False, 0)
        self.connect('delete-event', self.on_close)
        self.refresh_texts()

    def model(self):
        return core.chart_model(self.app.chart_limits(), core.read_history(self.app.history_path()), self.kind)

    def refresh_texts(self):
        t = self.app.t
        self.set_title(t['chart_title'])
        self.b5.set_label(t['five'])
        self.bw.set_label(t['week'])
        self.forecast.set_text(core.forecast_text(self.model(), t))
        self.area.queue_draw()

    def on_kind(self, btn, kind):
        if btn.get_active():
            self.kind = kind
            self.refresh_texts()

    def on_draw(self, widget, cr):
        a = widget.get_allocation()
        draw_chart(cr, a.width, a.height, self.model(), self.app.t, self.hover)

    def on_motion(self, w, ev):
        self.hover = ev.x
        self.area.queue_draw()

    def on_leave(self, *a):
        self.hover = None
        self.area.queue_draw()

    def on_close(self, *a):
        self.hide()
        return True


# ---------- приложение ----------

class App:
    def __init__(self):
        self.cfg = core.read_config()
        self.t = core.STRINGS[core.resolve_lang(self.cfg['language'])]
        self.chart = None
        self.updating = False
        self.indicator = None
        self.status_icon = None
        if AppIndicator:
            Ind = AppIndicator.Indicator
            self.indicator = Ind.new('claude-limits', 'claude-limits-none-0', AppIndicator.IndicatorCategory.APPLICATION_STATUS)
            self.indicator.set_icon_theme_path(icon_dir())
            self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        else:
            self.status_icon = Gtk.StatusIcon()
            self.status_icon.connect('activate', self.popup)
            self.status_icon.connect('popup-menu', self.popup)
        self.monitor = LimitMonitoringService()
        self.phone = PhoneSync()
        for source in core.SOURCES:
            self.monitor.subscribe(source, self.on_metrics)
        self.monitor.watch('code')
        self.monitor.watch('desktop', self.cfg['desktop_path'])
        self.ticks = 0
        self.build_menu()
        self.update()
        GLib.timeout_add(1000, self.tick)

    @property
    def source(self):
        return core.SOURCES[self.cfg['active_tab']]

    def chart_limits(self, source=None):
        m = self.monitor.latest.get(source or self.source)
        return {core.FIVE: m.window(core.FIVE), core.WEEK: m.window(core.WEEK)} if core.ok_metrics(m) else None

    def history_path(self):
        return core.history_path() if self.source == 'code' else core.desktop_history_path()

    # --- меню ---
    def item(self, menu, label='', sensitive=True, cb=None, check=None):
        it = Gtk.CheckMenuItem(label=label) if check is not None else Gtk.MenuItem(label=label)
        if check is not None:
            it.set_active(check)
        it.set_sensitive(sensitive)
        if cb:
            it.connect('toggled' if check is not None else 'activate', cb)
        menu.append(it)
        return it

    def radio_group(self, menu, options, selected, cb):
        group, items = None, {}
        for key, name in options:
            ri = Gtk.RadioMenuItem.new_with_label_from_widget(group, name)
            group = ri
            ri.set_active(key == selected)
            ri.connect('toggled', cb, key)
            menu.append(ri)
            items[key] = ri
        return items

    def build_menu(self):
        t = self.t
        self.updating = True
        m = Gtk.Menu()
        self.tab_items = self.radio_group(m, [(i, core.SOURCE_NAMES[s]) for i, s in enumerate(core.SOURCES)],
                                          self.cfg['active_tab'], self.on_tab)
        m.append(Gtk.SeparatorMenuItem())
        self.rows = [self.item(m, sensitive=False) for _ in range(4)]
        self.mi_updated = self.item(m, sensitive=False)
        m.append(Gtk.SeparatorMenuItem())
        self.mi_chart = self.item(m, t['chart'], cb=self.open_chart)
        desktop = Gtk.MenuItem(label=t['desktop_folder'])
        sub = Gtk.Menu()
        self.mi_desktop_path = self.item(sub, sensitive=False)
        self.mi_desktop_auto = self.item(sub, t['desktop_auto'], cb=self.desktop_auto, check=not self.cfg['desktop_path'])
        self.item(sub, t['desktop_pick'], cb=self.desktop_pick)
        desktop.set_submenu(sub)
        m.append(desktop)
        self.mi_notif = self.item(m, t['notifications'], cb=self.toggle_notif, check=self.cfg['notifications'])
        self.mi_start = self.item(m, t['startup'], cb=self.toggle_startup, check=core.autostart_enabled())
        lang = Gtk.MenuItem(label=t['language'])
        sub = Gtk.Menu()
        self.lang_items = self.radio_group(sub, (('system', t['system']), ('ru', 'Русский'), ('en', 'English')),
                                           self.cfg['language'], self.on_lang)
        lang.set_submenu(sub)
        m.append(lang)
        self.mi_update = self.item(m, t['check_updates'], cb=self.on_update)
        self.set_update_state(getattr(self, 'update_state', ('idle', None)))
        m.append(Gtk.SeparatorMenuItem())
        self.item(m, t['quit'], cb=self.quit)
        m.show_all()
        self.menu = m
        if self.indicator:
            self.indicator.set_menu(m)
        self.updating = False

    def popup(self, *a):
        self.menu.popup_at_pointer(None)

    # --- данные ---
    def set_rows(self, lines):
        for i, mi in enumerate(self.rows):
            text = lines[i] if i < len(lines) else ''
            mi.set_label(text)
            mi.set_visible(bool(text))

    def update(self):
        t, source = self.t, self.source
        m = self.monitor.latest.get(source)
        desktop = self.monitor.latest.get('desktop')
        self.mi_desktop_path.set_label(desktop.log_path if desktop and desktop.log_path else t['desktop_no_path'])
        if core.ok_metrics(m):
            lines = []
            for w in m.windows:
                lines.extend(core.window_lines(w, t))
            self.set_rows(lines)
            self.mi_updated.set_label(t['updated'].format(core.format_ago(m.updated, t)))
            self.mi_updated.show()
        else:
            self.set_rows(core.empty_state_lines(source, m, t))
            self.mi_updated.hide()
        used = core.worst_used(m)
        name, path = make_icon(core.level(used) if used is not None else 'none', used)
        label = core.indicator_label(m)
        tip = core.tray_tooltip([self.monitor.latest.get(s) for s in core.SOURCES], t)
        if self.indicator:
            self.indicator.set_icon_full(name, tip)
            self.indicator.set_label(label, '100%')
            try:
                self.indicator.set_title(tip)
            except Exception:
                pass
        else:
            self.status_icon.set_from_file(path)
            self.status_icon.set_tooltip_text(tip)
        if self.chart and self.chart.get_visible():
            self.chart.refresh_texts()

    def on_metrics(self, m):
        if m.source == 'desktop':
            core.append_metrics_history(m)
        self.phone.offer(dict(self.monitor.latest))
        self.check_notifications(m.source)
        if m.source == self.source:
            self.update()

    def tick(self):
        try:
            self.monitor.dispatch()
            self.ticks += 1
            if self.ticks % 5 == 0:
                self.update()
                for source in core.SOURCES:
                    self.check_notifications(source)
                self.phone.tick()
        except Exception as e:  # не даём таймеру умереть
            print('update error:', e, file=sys.stderr)
        return True

    # --- уведомления ---
    def notify(self, title, body, urgency='normal'):
        if shutil.which('notify-send'):
            try:
                subprocess.Popen(['notify-send', '-a', self.t['title'], '-u', urgency, '-i',
                                  make_icon('red' if urgency == 'critical' else 'green', 100)[1], title, body],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return True
            except Exception:
                pass
        try:
            gi.require_version('Notify', '0.7')
            from gi.repository import Notify
            Notify.init('Claude Limits')
            Notify.Notification.new(title, body).show()
            return True
        except Exception:
            return False

    def check_notifications(self, source):
        m = self.monitor.latest.get(source)
        if not self.cfg['notifications'] or not core.ok_metrics(m):
            return
        changed = False
        for w in m.windows:
            ev = core.notify_event(core.notify_key(source, w), w, self.cfg['notified'],
                                   thresholds=core.notify_thresholds(w))
            if ev:
                changed = True
                self.notify(*core.format_notification(ev, w, source, self.t))
        if changed:
            core.save_config(self.cfg)

    # --- действия меню ---
    def open_chart(self, *a):
        if not self.chart:
            self.chart = ChartWindow(self)
        self.chart.refresh_texts()
        self.chart.show_all()
        self.chart.present()

    def on_tab(self, it, index):
        if self.updating or not it.get_active():
            return
        self.set_tab(index)

    def set_tab(self, index):
        if self.cfg['active_tab'] != index:
            self.cfg['active_tab'] = index
            core.save_config(self.cfg)
        self.update()
        if self.chart:
            self.chart.refresh_texts()

    def set_desktop_path(self, path):
        self.cfg['desktop_path'] = path
        core.save_config(self.cfg)
        self.monitor.watch('desktop', path)
        GLib.idle_add(self.rebuild)

    def desktop_auto(self, it):
        if not self.updating and self.cfg['desktop_path']:
            self.set_desktop_path('')
        elif not self.updating:
            self.rebuild()

    def desktop_pick(self, *a):
        dlg = Gtk.FileChooserDialog(title=self.t['desktop_pick_title'], action=Gtk.FileChooserAction.SELECT_FOLDER)
        dlg.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        start = self.cfg['desktop_path'] or os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.join(core.home(), '.config'))
        if os.path.isdir(start):
            dlg.set_current_folder(start)
        try:
            if dlg.run() == Gtk.ResponseType.OK and dlg.get_filename():
                self.set_desktop_path(dlg.get_filename())
        finally:
            dlg.destroy()

    # --- обновления ---
    def set_update_state(self, state):
        self.update_state = state
        kind, version = state
        t = self.t
        labels = {'idle': t['check_updates'], 'checking': t['checking_updates'],
                  'current': t['up_to_date'].format(core.installed_version()),
                  'available': t['update_to'].format(version), 'failed': t['update_failed'],
                  'installing': t['installing_update']}
        self.mi_update.set_label(labels[kind])
        self.mi_update.set_sensitive(kind not in ('checking', 'installing'))
        return False

    def on_update(self, *a):
        kind, version = self.update_state
        if kind == 'available':
            self.set_update_state(('installing', version))
            os.makedirs(core.config_dir(), exist_ok=True)
            log = open(os.path.join(core.config_dir(), 'update.log'), 'w')
            subprocess.Popen(core.update_command(), stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                             start_new_session=True)
            return
        self.set_update_state(('checking', None))

        def worker():
            try:
                remote = core.fetch_remote_version()
                state = ('available', remote) if core.is_newer(remote, core.installed_version()) else ('current', None)
            except Exception:
                state = ('failed', None)
            GLib.idle_add(self.set_update_state, state)

        threading.Thread(target=worker, daemon=True).start()

    def quit(self, *a):
        self.monitor.close()
        Gtk.main_quit()

    def toggle_notif(self, it):
        if self.updating:
            return
        self.cfg['notifications'] = it.get_active()
        core.save_config(self.cfg)
        if it.get_active():
            self.notify(self.t['notif_on_title'], self.t['notif_on_body'])

    def toggle_startup(self, it):
        if self.updating:
            return
        core.set_autostart(it.get_active(), APP_PATH)

    def on_lang(self, it, code):
        if self.updating or not it.get_active():
            return
        self.set_language(code)

    def set_language(self, code):
        self.cfg['language'] = code
        core.save_config(self.cfg)
        self.t = core.STRINGS[core.resolve_lang(code)]
        GLib.idle_add(self.rebuild)

    def rebuild(self):
        self.build_menu()
        self.update()
        if self.chart:
            self.chart.refresh_texts()
        return False


def selftest(app):
    out_dir = os.environ.get('CLAUDE_LIMITS_SELFTEST_OUT')
    if not app.monitor.wait_for_all(30):
        raise RuntimeError('monitoring timeout')
    for code in ('ru', 'en', 'system'):
        app.cfg['language'] = code
        app.t = core.STRINGS[core.resolve_lang(code)]
        app.rebuild()
    tabs = []
    for i in reversed(range(len(core.SOURCES))):
        app.set_tab(i)
        tabs.append('{0}: {1}'.format(core.SOURCES[i], app.rows[0].get_label()))
    app.monitor.watch('desktop', os.path.join(core.home(), 'cl-missing-desktop'))
    if not app.monitor.wait_for_all(10):
        raise RuntimeError('monitoring timeout after desktop path change')
    app.set_tab(1)
    if app.rows[0].get_label() != app.t['desktop_not_found']:
        raise RuntimeError('desktop not-found state: ' + app.rows[0].get_label())
    app.set_tab(0)
    app.open_chart()
    for b in (app.chart.bw, app.chart.b5):
        b.set_active(True)
    while Gtk.events_pending():
        Gtk.main_iteration_do(False)
    for kind in (core.FIVE, core.WEEK):
        surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, 520, 240)
        model = core.chart_model(app.chart_limits(), core.read_history(app.history_path()), kind)
        draw_chart(cairo.Context(surf), 520, 240, model, app.t, hover_x=300)
        if out_dir:
            surf.write_to_png(os.path.join(out_dir, 'chart-{0}.png'.format(kind)))
    app.notify('Claude Limits', 'selftest')
    print('SELFTEST OK | label: {0} | {1} | indicator: {2} | forecast: {3}'.format(
        core.indicator_label(app.monitor.latest.get('code')), ' | '.join(tabs),
        'AppIndicator' if app.indicator else 'StatusIcon', app.chart.forecast.get_text()))
    app.monitor.close()


def main():
    lock_dir = os.environ.get('XDG_RUNTIME_DIR') or core.config_dir()
    os.makedirs(lock_dir, exist_ok=True)
    lock = open(os.path.join(lock_dir, 'claude-limits{0}.lock'.format('-selftest' if SELFTEST else '')), 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print('Claude Limits уже запущен.')
        return 0
    app = App()
    if SELFTEST:
        try:
            selftest(app)
            return 0
        except Exception as e:
            import traceback
            traceback.print_exc()
            print('SELFTEST FAIL:', e)
            return 1
    Gtk.main()
    return 0


if __name__ == '__main__':
    sys.exit(main())
