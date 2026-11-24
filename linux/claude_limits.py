#!/usr/bin/env python3
# ClaudeLimits for Linux — значок в трее (GTK3 + AyatanaAppIndicator/AppIndicator, запасной вариант — Gtk.StatusIcon).
# Нужны пакеты: python3-gi, gir1.2-ayatanaappindicator3-0.1 (или аналог), libnotify-bin — их ставит install.sh.
# CLAUDE_LIMITS_SELFTEST=1 — автотест: собрать интерфейс, прогнать языки и график, выйти.
import fcntl
import importlib
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import claude_limits_core as core  # noqa: E402

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
        return core.chart_model(self.app.limits, core.read_history(), self.kind)

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
        self.limits = None
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
        self.build_menu()
        self.update()
        GLib.timeout_add_seconds(5, self.tick)

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

    def build_menu(self):
        t = self.t
        self.updating = True
        m = Gtk.Menu()
        self.mi_five = self.item(m, sensitive=False)
        self.mi_five_reset = self.item(m, sensitive=False)
        self.mi_week = self.item(m, sensitive=False)
        self.mi_week_reset = self.item(m, sensitive=False)
        self.mi_updated = self.item(m, sensitive=False)
        m.append(Gtk.SeparatorMenuItem())
        self.item(m, t['chart'], cb=self.open_chart)
        self.mi_notif = self.item(m, t['notifications'], cb=self.toggle_notif, check=self.cfg['notifications'])
        self.mi_start = self.item(m, t['startup'], cb=self.toggle_startup, check=core.autostart_enabled())
        lang = Gtk.MenuItem(label=t['language'])
        sub = Gtk.Menu()
        group = None
        self.lang_items = {}
        for code, name in (('system', t['system']), ('ru', 'Русский'), ('en', 'English')):
            ri = Gtk.RadioMenuItem.new_with_label_from_widget(group, name)
            group = ri
            ri.set_active(self.cfg['language'] == code)
            ri.connect('toggled', self.on_lang, code)
            sub.append(ri)
            self.lang_items[code] = ri
        lang.set_submenu(sub)
        m.append(lang)
        m.append(Gtk.SeparatorMenuItem())
        self.item(m, t['quit'], cb=lambda *a: Gtk.main_quit())
        m.show_all()
        self.menu = m
        if self.indicator:
            self.indicator.set_menu(m)
        self.updating = False

    def popup(self, *a):
        self.menu.popup_at_pointer(None)

    # --- данные ---
    def update(self):
        t = self.t
        self.limits = core.read_limits()
        lim = self.limits
        has = lim and (lim.get(core.FIVE) or lim.get(core.WEEK))
        for kind, mi, mr, name in ((core.FIVE, self.mi_five, self.mi_five_reset, t['five']),
                                   (core.WEEK, self.mi_week, self.mi_week_reset, t['week'])):
            w = lim.get(kind) if lim else None
            if w:
                mi.set_label(t['left_used'].format(name, int(round(w['left'])), int(round(w['used']))))
                mr.set_label('    ' + t['reset'].format(core.format_countdown(w['reset'], t)))
                mr.show()
            else:
                mi.set_label('{0}: {1}'.format(name, t['no_data']))
                mr.hide()
        self.mi_updated.set_label(t['updated'].format(core.format_ago(lim['updated'], t)) if has else t['no_data_long'])
        used = core.worst_used(lim)
        name, path = make_icon(core.level(used) if used is not None else 'none', used)
        label = core.indicator_label(lim)
        tip = '{0}: {1}'.format(t['title'], label)
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
        self.check_notifications()

    def tick(self):
        try:
            self.update()
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

    def check_notifications(self):
        if not self.cfg['notifications'] or not self.limits:
            return
        changed = False
        for kind in (core.FIVE, core.WEEK):
            w = self.limits.get(kind)
            if not w:
                continue
            ev = core.notify_event(kind, w, self.cfg['notified'])
            if ev:
                changed = True
                self.notify(*core.format_notification(ev, w, kind == core.FIVE, self.t))
        if changed:
            core.save_config(self.cfg)

    # --- действия меню ---
    def open_chart(self, *a):
        if not self.chart:
            self.chart = ChartWindow(self)
        self.chart.refresh_texts()
        self.chart.show_all()
        self.chart.present()

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
    for code in ('ru', 'en', 'system'):
        app.cfg['language'] = code
        app.t = core.STRINGS[core.resolve_lang(code)]
        app.rebuild()
    app.open_chart()
    for b in (app.chart.bw, app.chart.b5):
        b.set_active(True)
    while Gtk.events_pending():
        Gtk.main_iteration_do(False)
    for kind in (core.FIVE, core.WEEK):
        surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, 520, 240)
        model = core.chart_model(app.limits, core.read_history(), kind)
        draw_chart(cairo.Context(surf), 520, 240, model, app.t, hover_x=300)
        if out_dir:
            surf.write_to_png(os.path.join(out_dir, 'chart-{0}.png'.format(kind)))
    app.notify('Claude Limits', 'selftest')
    print('SELFTEST OK | label: {0} | menu: {1} | indicator: {2} | forecast: {3}'.format(
        core.indicator_label(app.limits), app.mi_five.get_label(),
        'AppIndicator' if app.indicator else 'StatusIcon', app.chart.forecast.get_text()))


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
