# ClaudeLimits for Linux — фоновый опрос источников (LimitMonitoringService).
# Каждый источник опрашивается в своём потоке: изменения файлов определяются по размеру и mtime
# (с debounce, чтобы не реагировать на каждую запись LevelDB), плюс полный разбор раз в interval.
# Новые снимки LimitMetrics кладутся в queue.Queue; dispatch() вызывается из главного потока (GLib)
# и раздаёт их подписчикам.
import os
import queue
import threading
import time
import uuid

import claude_limits_parsers as parsers


def path_signature(path):
    """Размер и mtime файла или всех файлов папки: меняется при любой записи."""
    if not path:
        return None
    try:
        if os.path.isdir(path):
            out = []
            for e in os.scandir(path):
                try:
                    st = e.stat()
                    out.append((e.name, st.st_size, st.st_mtime_ns))
                except OSError:
                    pass
            return tuple(sorted(out))
        st = os.stat(path)
        return (st.st_size, st.st_mtime_ns)
    except OSError:
        return None


class _Worker(threading.Thread):
    def __init__(self, service, source, path):
        super().__init__(daemon=True, name='claude-limits-' + source)
        self.id = uuid.uuid4().hex
        self.service = service
        self.source = source
        self.path = path
        self.stop_event = threading.Event()

    def run(self):
        parser = parsers.new_parser(self.source, self.path)
        svc = self.service
        last = None
        while not self.stop_event.is_set():
            try:
                m = parser.parse_limits()
                sig = (m.status, m.updated, m.log_path,
                       tuple((w['id'], w['used'], w['reset']) for w in m.windows))
                if sig != last:
                    last = sig
                    svc.queue.put((self.id, self.source, m))
            except Exception:
                pass
            self._wait_for_change(parser.get_log_path(), svc.interval, svc.debounce)

    def _wait_for_change(self, target, interval, debounce):
        start = path_signature(target)
        deadline = time.monotonic() + interval
        while time.monotonic() < deadline:
            if self.stop_event.wait(min(0.5, debounce)):
                return
            sig = path_signature(target)
            if sig != start:
                cap = time.monotonic() + 10 * debounce
                while time.monotonic() < cap and not self.stop_event.wait(debounce):
                    nxt = path_signature(target)
                    if nxt == sig:
                        return
                    sig = nxt
                return


class LimitMonitoringService:
    def __init__(self, interval=5.0, debounce=0.75):
        self.interval = interval
        self.debounce = debounce
        self.queue = queue.Queue()
        self.latest = {}
        self.workers = {}
        self.handlers = {}

    def subscribe(self, source, handler):
        self.handlers.setdefault(source, []).append(handler)

    def watch(self, source, path=None):
        self.unwatch(source)
        w = _Worker(self, source, path)
        self.workers[source] = w
        w.start()

    def unwatch(self, source):
        w = self.workers.pop(source, None)
        self.latest.pop(source, None)
        if w:
            w.stop_event.set()

    def dispatch(self):
        count = 0
        while True:
            try:
                wid, source, m = self.queue.get_nowait()
            except queue.Empty:
                return count
            w = self.workers.get(source)
            if not w or w.id != wid:
                continue
            self.latest[source] = m
            for h in self.handlers.get(source, []):
                try:
                    h(m)
                except Exception:
                    pass
            count += 1

    def wait_for_all(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            self.dispatch()
            if all(s in self.latest for s in self.workers):
                return True
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.05)

    def close(self):
        workers = list(self.workers.values())
        for source in list(self.workers):
            self.unwatch(source)
        for w in workers:
            w.join(timeout=3)
        self.handlers.clear()
        while not self.queue.empty():
            self.queue.get_nowait()
