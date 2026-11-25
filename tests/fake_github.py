# Поддельный GitHub Gist API для интеграционных тестов выгрузки на телефон.
#   python3 tests/fake_github.py <папка>   — пишет порт в <папка>/port, каждый gist — в <папка>/<id>.json,
#   журнал запросов — в <папка>/requests.log. Принимает только токен «good».
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

DIR = sys.argv[1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_one(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n) or b'{}') if n else {}
        with open(os.path.join(DIR, 'requests.log'), 'a') as f:
            f.write('{0} {1} {2}\n'.format(self.command, self.path, self.headers.get('Authorization')))
        gid = self.path.rstrip('/').rsplit('/', 1)[-1]
        path = os.path.join(DIR, gid + '.json')
        if self.command == 'GET':
            if os.path.exists(path):
                with open(path) as f:
                    return self.reply(200, json.load(f))
            return self.reply(404, {'message': 'Not Found'})
        if self.headers.get('Authorization') != 'Bearer good':
            return self.reply(401, {'message': 'Bad credentials'})
        if self.command == 'POST' and self.path == '/gists':
            gid = 'g{0}'.format(len([x for x in os.listdir(DIR) if x.startswith('g') and x.endswith('.json')]) + 1)
            path = os.path.join(DIR, gid + '.json')
        elif not os.path.exists(path):
            return self.reply(404, {'message': 'Not Found'})
        with open(path, 'w') as f:
            json.dump(body, f)
        return self.reply(201 if self.command == 'POST' else 200, {'id': gid})

    do_GET = do_POST = do_PATCH = handle_one


server = HTTPServer(('127.0.0.1', 0), Handler)
with open(os.path.join(DIR, 'port.tmp'), 'w') as f:
    f.write(str(server.server_port))
os.replace(os.path.join(DIR, 'port.tmp'), os.path.join(DIR, 'port'))
server.serve_forever()
