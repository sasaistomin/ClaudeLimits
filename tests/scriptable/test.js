// Тесты логики виджета Scriptable (scriptable/ClaudeLimits.js) в node:  node tests/scriptable/test.js
// Скрипт написан для Scriptable (top-level await), поэтому выполняем его внутри async-функции.
const assert = require('assert')
const fs = require('fs')
const path = require('path')

const src = fs.readFileSync(path.join(__dirname, '../../scriptable/ClaudeLimits.js'), 'utf8')
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

let passed = 0
const failed = []
function test(name, fn) {
  try { fn(); passed++ } catch (e) { failed.push(`${name}: ${e.message}`) }
}

;(async () => {
  const mod = { exports: {} }
  await new AsyncFunction('module', src)(mod)
  const W = mod.exports
  const NOW = 1800000000

  const payload = {
    v: 1, sent_at: NOW,
    sources: {
      code: { updated: NOW - 120, windows: [
        { id: 'five_hour', used: 79, resets_at: NOW + 2 * 3600 + 600, rolling: false },
        { id: 'seven_day', used: 13, resets_at: NOW + 3 * 86400 + 3600, rolling: false }] },
      desktop: { updated: NOW - 7200, windows: [
        { id: 'five_hour', used: 95, resets_at: NOW - 10, rolling: true }] },
    },
  }

  test('parseParameter: ID, источник, ссылка на gist, запасной ID', () => {
    assert.deepStrictEqual(W.parseParameter('abc123', ''), { id: 'abc123', source: null })
    assert.deepStrictEqual(W.parseParameter(' abc123 desktop ', ''), { id: 'abc123', source: 'desktop' })
    assert.deepStrictEqual(W.parseParameter('code,abc', ''), { id: 'abc', source: 'code' })
    assert.strictEqual(W.parseParameter('https://gist.github.com/user/f00d', '').id, 'f00d')
    assert.strictEqual(W.parseParameter('https://gist.github.com/f00d#file', '').id, 'f00d')
    assert.strictEqual(W.parseParameter('', 'fallback').id, 'fallback')
    assert.strictEqual(W.parseParameter(null, '').id, '')
  })

  test('level и countdown как в приложении', () => {
    assert.strictEqual(W.level(69.9), 'green')
    assert.strictEqual(W.level(70), 'yellow')
    assert.strictEqual(W.level(90), 'red')
    const ru = W.strings('ru-RU'), en = W.strings('en')
    assert.strictEqual(W.countdown(NOW + 2 * 3600 + 600, NOW, ru), 'через 2 ч 10 мин')
    assert.strictEqual(W.countdown(NOW + 3 * 86400 + 3600, NOW, en), 'in 3d 1h')
    assert.strictEqual(W.countdown(NOW + 59, NOW, ru), 'через 0 мин')
    assert.strictEqual(W.countdown(NOW, NOW, ru), 'сброшен')
  })

  test('payloadFromGist: файл, битый JSON, нет файла', () => {
    const gist = { files: { 'claude-limits.json': { content: JSON.stringify(payload) } } }
    assert.deepStrictEqual(W.payloadFromGist(gist), payload)
    assert.strictEqual(W.payloadFromGist({ files: { 'claude-limits.json': { content: '{' } } }), null)
    assert.strictEqual(W.payloadFromGist({ files: {} }), null)
    assert.strictEqual(W.payloadFromGist(null), null)
  })

  test('buildModel: остаток, цвет, прошедшее окно обнулено, свежесть', () => {
    const m = W.buildModel(payload, NOW, 'ru')
    assert.strictEqual(m.sources.length, 2)
    const [code, desktop] = m.sources
    assert.strictEqual(code.name, 'Claude Code')
    assert.deepStrictEqual(code.windows.map((w) => [w.title, w.left, w.level]), [['5 часов', 21, 'yellow'], ['Неделя', 87, 'green']])
    assert.strictEqual(code.windows[0].countdown, 'через 2 ч 10 мин')
    assert.strictEqual(code.ago, '2 мин назад')
    assert.strictEqual(code.stale, false)
    assert.deepStrictEqual(desktop.windows.map((w) => [w.title, w.left, w.level, w.countdown]), [['5 ч (скольз.)', 100, 'green', '']])
    assert.strictEqual(desktop.stale, true)
    assert.strictEqual(W.buildModel(payload, NOW, 'en').sources[0].windows[1].title, 'Week')
  })

  test('buildModel: пустые и кривые данные не ломают виджет', () => {
    assert.deepStrictEqual(W.buildModel(null, NOW, 'ru').sources, [])
    assert.deepStrictEqual(W.buildModel({ sources: { code: { windows: [] } } }, NOW, 'ru').sources, [])
    const m = W.buildModel({ sources: { code: { windows: [{ id: 'five_hour', used: 'x', resets_at: NOW + 60 }] } } }, NOW, 'ru')
    assert.strictEqual(m.sources[0].windows[0].left, 100)
    assert.strictEqual(m.sources[0].stale, true)
    assert.strictEqual(W.buildModel({ sources: { code: { windows: [{ id: 'five_hour', used: 140, resets_at: NOW + 60 }] } } }, NOW, 'ru').sources[0].windows[0].left, 0)
  })

  test('arcPoints: дуга от 12 часов по часовой стрелке', () => {
    const near = (a, b) => Math.abs(a - b) < 1e-9
    const quarter = W.arcPoints(50, 50, 40, 0.25, 3)
    assert.ok(near(quarter[0][0], 50) && near(quarter[0][1], 10), 'начало сверху')
    const end = quarter[quarter.length - 1]
    assert.ok(near(end[0], 90) && near(end[1], 50), 'четверть — справа')
    const full = W.arcPoints(50, 50, 40, 1, 3)
    assert.strictEqual(full.length, 121)
    assert.ok(full.every(([x, y]) => near(Math.hypot(x - 50, y - 50), 40)), 'все точки на окружности')
    assert.strictEqual(W.arcPoints(0, 0, 1, 2).length, W.arcPoints(0, 0, 1, 1).length, 'больше круга не рисуем')
    assert.ok(W.arcPoints(0, 0, 1, 0).length >= 2, 'нулевая дуга не ломает Path')
  })

  test('короткий обратный отсчёт', () => {
    assert.strictEqual(W.countdown(NOW + 2 * 3600 + 600, NOW, W.strings('ru'), true), '2 ч 10 м')
    assert.strictEqual(W.countdown(NOW + 3 * 86400 + 3600, NOW, W.strings('en'), true), '3d 1h')
    assert.strictEqual(W.countdown(NOW + 300, NOW, W.strings('ru'), true), '5 мин')
  })

  test('pickSource: заданный, иначе самый свежий', () => {
    const m = W.buildModel(payload, NOW, 'ru')
    assert.strictEqual(W.pickSource(m, 'desktop').key, 'desktop')
    assert.strictEqual(W.pickSource(m, null).key, 'code')
    assert.strictEqual(W.pickSource(m, 'nope').key, 'code')
    assert.strictEqual(W.pickSource(W.buildModel(null, NOW, 'ru'), null), null)
  })

  test('формат совпадает с тем, что выгружают приложения', () => {
    const fixture = JSON.parse(fs.readFileSync(path.join(__dirname, 'payload.json'), 'utf8'))
    const m = W.buildModel(fixture, fixture.sent_at, 'en')
    assert.deepStrictEqual(m.sources.map((s) => s.key), ['code', 'desktop'])
    assert.ok(m.sources.every((s) => s.windows.length > 0 && s.windows.every((w) => w.left >= 0 && w.left <= 100)))
  })


  // Полный прогон скрипта с поддельным API Scriptable: все размеры виджета, кэш, нет связи, нет ID.
  function fakeScriptable({ family, param, fetchOk = true, lang = 'ru', inWidget = true }) {
    const log = { texts: [], widget: null, presented: false, completed: false, requests: 0, images: 0 }
    class El { constructor() { this.children = [] } }
    class Stack extends El {
      addStack() { const s = new Stack(); this.children.push(s); return s }
      addText(v) { assert.strictEqual(typeof v, 'string'); log.texts.push(v); const t = new El(); t.text = v; this.children.push(t); return t }
      addImage(img) { assert.ok(img && img.drawn, 'картинка нарисована'); const i = new El(); this.children.push(i); return i }
      addSpacer() {} layoutHorizontally() {} layoutVertically() {} centerAlignContent() {} setPadding() {}
    }
    const files = {}
    const g = {
      ListWidget: class extends Stack { async presentMedium() { log.presented = true } },
      Font: new Proxy({}, { get: () => (size) => ({ size }) }),
      Color: Object.assign(class { constructor(hex, a) { this.hex = hex; this.a = a } }, {
        dynamic: (a, b) => ({ a, b }), black: () => ({}), white: () => ({}) }),
      Size: class { constructor(w, h) { this.w = w; this.h = h } },
      Rect: class { constructor(...a) { this.a = a } },
      Point: class { constructor(x, y) { assert.ok(Number.isFinite(x) && Number.isFinite(y), 'точка'); this.x = x; this.y = y } },
      Path: class { addRoundedRect() {} addLines(pts) { assert.ok(pts.length >= 2, 'линия из точек') } },
      DrawContext: class {
        addPath() {} setFillColor() {} fillPath() {} setStrokeColor() {} setLineWidth() {} strokePath() {} fillEllipse() {}
        getImage() { log.images++; return { drawn: true } }
      },
      Request: class {
        constructor(url) { this.url = url }
        async loadJSON() {
          log.requests++
          if (!fetchOk) throw new Error('offline')
          assert.ok(this.url.endsWith('/gists/abc123'), this.url)
          return { files: { 'claude-limits.json': { content: JSON.stringify(payload) } } }
        }
      },
      FileManager: { local: () => ({
        cacheDirectory: () => '/cache', joinPath: (a, b) => a + '/' + b,
        fileExists: (p) => p in files, readString: (p) => files[p], writeString: (p, v) => { files[p] = v } }) },
      Device: { language: () => lang },
      config: { widgetFamily: family, runsInWidget: inWidget && !String(family).startsWith('accessory'),
                runsInAccessoryWidget: inWidget && String(family).startsWith('accessory') },
      args: { widgetParameter: param },
      Script: { setWidget: (w) => { log.widget = w }, complete: () => { log.completed = true } },
      Date: class extends Date { static now() { return NOW * 1000 } },
    }
    return { g, log, files }
  }
  async function runScript(env) {
    const names = Object.keys(env.g)
    await new AsyncFunction(...names, 'module', src)(...names.map((n) => env.g[n]), { exports: {} })
    return env.log
  }

  // payload: Code 5 ч — осталось 21% (сброс через 2 ч 10 м), неделя 87%; Desktop — окно прошло, 100%.
  const expect = {
    small: ['Claude Code', '21%', '5 ч', '2 ч 10 м', 'Неделя', '87%'],
    medium: ['Claude Code', 'Claude Desktop', '21%', '100%', 'сброс 2 ч 10 м', '87%', '2 мин назад'],
    large: ['Claude Code', 'Claude Desktop', '21%', '87%'],
    accessoryCircular: ['21', '5 ч'],
    accessoryRectangular: ['Claude Code', '5 ч', '21%', 'Нед.', '87%', 'сброс 2 ч 10 м'],
    accessoryInline: ['✳︎ 21% · 2 ч 10 м · Нед. 87%'],
  }
  for (const [family, texts] of Object.entries(expect)) {
    const log = await runScript(fakeScriptable({ family, param: 'abc123' }))
    test(`отрисовка: ${family}`, () => {
      assert.ok(log.widget && log.completed, 'виджет передан в Script.setWidget')
      for (const t of texts) assert.ok(log.texts.includes(t), `нет «${t}» в: ${log.texts.join(' | ')}`)
      if (family !== 'accessoryInline') assert.ok(log.images > 0, 'кольца и полоски нарисованы')
    })
  }
  {
    const log = await runScript(fakeScriptable({ family: 'medium', param: 'abc123 desktop' }))
    test('2×4 с источником desktop: только он', () => {
      assert.ok(log.texts.includes('Claude Desktop') && !log.texts.includes('Claude Code'), log.texts.join(' | '))
    })
  }
  {
    const log = await runScript(fakeScriptable({ family: 'small', param: 'abc123 desktop' }))
    test('маленький виджет с источником desktop', () => assert.ok(log.texts.includes('Claude Desktop'), log.texts.join(' | ')))
  }
  {
    const env = fakeScriptable({ family: 'medium', param: 'abc123' })
    await runScript(env)
    const cached = JSON.parse(Object.values(env.files)[0])
    cached.fetched -= 3600 // кэш устарел
    env.files[Object.keys(env.files)[0]] = JSON.stringify(cached)
    const off = fakeScriptable({ family: 'medium', param: 'abc123', fetchOk: false })
    Object.assign(off.files, env.files)
    const log = await runScript(off)
    test('нет связи: показаны данные из кэша с пометкой', () => {
      assert.ok(log.texts.includes('Нет связи, показаны прошлые данные'), log.texts.join(' | '))
      assert.ok(log.texts.includes('Claude Code'))
    })
    const fresh = fakeScriptable({ family: 'medium', param: 'abc123', fetchOk: false })
    Object.assign(fresh.files, env.files)
    fresh.files[Object.keys(env.files)[0]] = JSON.stringify(Object.assign(cached, { fetched: NOW }))
    const log2 = await runScript(fresh)
    test('свежий кэш: без запроса к GitHub', () => assert.strictEqual(log2.requests, 0))
  }
  {
    const log = await runScript(fakeScriptable({ family: 'medium', param: '' }))
    test('нет ID: подсказка', () => assert.ok(log.texts.includes('Укажите ID gist'), log.texts.join(' | ')))
    const log2 = await runScript(fakeScriptable({ family: 'medium', param: 'abc123', fetchOk: false, lang: 'en' }))
    test('нет связи и кэша: «No data»', () => assert.ok(log2.texts.includes('No data'), log2.texts.join(' | ')))
    const log3 = await runScript(fakeScriptable({ family: undefined, param: 'abc123', inWidget: false }))
    test('запуск в приложении: предпросмотр', () => assert.ok(log3.presented && log3.completed))
  }

  console.log(`Scriptable: пройдено ${passed}, ошибок ${failed.length}`)
  failed.forEach((f) => console.log('  ✗ ' + f))
  process.exit(failed.length ? 1 : 0)
})().catch((e) => { console.log('Scriptable: ошибка загрузки скрипта: ' + e.message); process.exit(1) })
