// Claude Limits — виджет для iPhone/iPad (приложение Scriptable).
// Показывает остаток лимитов Claude Code и Claude Desktop, которые компьютер выгружает в секретный GitHub Gist.
//
// Настройка:
//   1. На компьютере: ClaudeLimits --phone-setup (macOS), phone.ps1 setup (Windows),
//      claude_limits_phone.py setup (Linux) — команда напечатает ID для виджета.
//   2. В Scriptable: «+», вставить этот файл целиком, назвать «Claude Limits».
//   3. Добавить на экран виджет Scriptable, Script: Claude Limits, Parameter: ID из шага 1.
//      Можно дописать через пробел источник: «<ID> desktop» — виджет покажет только Claude Desktop.
//
// Варианты (размер выбирается при добавлении виджета):
//   2×2 (small)            — кольцо остатка 5-часового окна, время до сброса, неделя полоской;
//   2×4 (medium, и large)  — Claude Code и Claude Desktop рядом: кольцо 5 ч, сброс, неделя;
//   экран блокировки       — круглый (кольцо с процентом), прямоугольный (две полоски), строка над часами.
//   Или впишите ID ниже — тогда Parameter можно оставить пустым.
//
// Данные обновляются, только пока на компьютере работает значок Claude Limits и вы пишете Claude.
// Покрыто тестами: tests/scriptable/test.js

const GIST_ID = ''

const GIST_FILE = 'claude-limits.json'
const CACHE_FILE = 'claude-limits-cache.json'
const CACHE_TTL = 60
const STALE_AFTER = 3600

const STRINGS = {
  ru: {
    five: '5 часов', week: 'Неделя', rolling: '5 ч (скольз.)', left: 'осталось', reset: 'сброс', done: 'сброшен',
    in: (d, h, m) => d > 0 ? `через ${d} д ${h} ч` : h > 0 ? `через ${h} ч ${m} мин` : `через ${m} мин`,
    short: (d, h, m) => d > 0 ? `${d} д ${h} ч` : h > 0 ? `${h} ч ${m} м` : `${m} мин`,
    five1: '5 ч', week1: 'Нед.',
    ago: (s) => s < 60 ? 'только что' : s < 3600 ? `${Math.floor(s / 60)} мин назад`
      : s < 86400 ? `${Math.floor(s / 3600)} ч назад` : `${Math.floor(s / 86400)} д назад`,
    updated: 'обновлено', noData: 'Нет данных', noDataHint: 'Отправьте сообщение Claude на компьютере.',
    noId: 'Укажите ID gist', noIdHint: 'Parameter виджета или GIST_ID в скрипте.',
    offline: 'Нет связи, показаны прошлые данные',
  },
  en: {
    five: '5 hours', week: 'Week', rolling: '5h (rolling)', left: 'left', reset: 'resets', done: 'done',
    in: (d, h, m) => d > 0 ? `in ${d}d ${h}h` : h > 0 ? `in ${h}h ${m}m` : `in ${m}m`,
    short: (d, h, m) => d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`,
    five1: '5h', week1: 'Wk',
    ago: (s) => s < 60 ? 'just now' : s < 3600 ? `${Math.floor(s / 60)}m ago`
      : s < 86400 ? `${Math.floor(s / 3600)}h ago` : `${Math.floor(s / 86400)}d ago`,
    updated: 'updated', noData: 'No data', noDataHint: 'Send Claude a message on your computer.',
    noId: 'Set the gist ID', noIdHint: 'Widget Parameter or GIST_ID in the script.',
    offline: 'Offline, showing cached data',
  },
}

const SOURCE_NAMES = { code: 'Claude Code', desktop: 'Claude Desktop' }
const COLORS = { green: '#34C759', yellow: '#FFB800', red: '#FF3B30', none: '#8E8E93' }

// ---------- чистая логика (тестируется в node) ----------

function strings(lang) { return STRINGS[String(lang || '').toLowerCase().startsWith('ru') ? 'ru' : 'en'] }

function parseParameter(param, fallbackId) {
  const parts = String(param || '').trim().split(/[\s,;|]+/).filter(Boolean)
  const source = parts.find((p) => p === 'code' || p === 'desktop') || null
  const id = parts.find((p) => p !== 'code' && p !== 'desktop') || fallbackId || ''
  return { id: id.replace(/^https?:\/\/gist\.github\.com\/(?:[^/]+\/)?/, '').replace(/[/#?].*$/, ''), source }
}

function level(used) { return used >= 90 ? 'red' : used >= 70 ? 'yellow' : 'green' }

function countdown(resetsAt, now, t, short) {
  const s = Math.floor(resetsAt - now)
  if (s <= 0) return t.done
  return (short ? t.short : t.in)(Math.floor(s / 86400), Math.floor((s % 86400) / 3600), Math.floor((s % 3600) / 60))
}

// Точки дуги кольца: от 12 часов по часовой стрелке, fraction — доля круга (0…1).
function arcPoints(cx, cy, r, fraction, step) {
  const f = Math.max(0, Math.min(1, fraction))
  const n = Math.max(1, Math.ceil((360 * f) / (step || 3)))
  const pts = []
  for (let i = 0; i <= n; i++) {
    const a = -Math.PI / 2 + (2 * Math.PI * f * i) / n
    pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)])
  }
  return pts
}

function payloadFromGist(gist) {
  const f = gist && gist.files && gist.files[GIST_FILE]
  if (!f || typeof f.content !== 'string') return null
  try { return JSON.parse(f.content) } catch (e) { return null }
}

// Модель для отрисовки: окна по источникам, прошедшие окна считаются обнулёнными (как в приложении).
function buildModel(payload, now, lang) {
  const t = strings(lang)
  const sources = []
  const raw = (payload && payload.sources) || {}
  for (const key of ['code', 'desktop']) {
    const s = raw[key]
    if (!s || !Array.isArray(s.windows) || s.windows.length === 0) continue
    const windows = s.windows.map((w) => {
      const used = w.resets_at <= now ? 0 : Math.max(0, Math.min(100, Number(w.used) || 0))
      const title = w.rolling ? t.rolling : w.id === 'five_hour' ? t.five : t.week
      const live = w.resets_at > now
      return {
        id: w.id, title, short: w.id === 'five_hour' ? t.five1 : t.week1, used, left: Math.round(100 - used),
        level: level(used), resetsAt: w.resets_at,
        countdown: live ? countdown(w.resets_at, now, t) : '', countdownShort: live ? countdown(w.resets_at, now, t, true) : '',
      }
    })
    const updated = Number(s.updated) || 0
    sources.push({ key, name: SOURCE_NAMES[key], windows, updated,
      ago: updated ? t.ago(Math.max(0, now - updated)) : '', stale: !updated || now - updated > STALE_AFTER })
  }
  return { sources, t }
}

// Какой источник показать в маленьком виджете: заданный, иначе самый свежий.
function pickSource(model, wanted) {
  if (wanted) {
    const s = model.sources.find((x) => x.key === wanted)
    if (s) return s
  }
  return model.sources.slice().sort((a, b) => b.updated - a.updated)[0] || null
}

// ---------- Scriptable ----------

async function loadPayload(id) {
  const fm = FileManager.local()
  const cachePath = fm.joinPath(fm.cacheDirectory(), CACHE_FILE)
  let cache = null
  if (fm.fileExists(cachePath)) {
    try { cache = JSON.parse(fm.readString(cachePath)) } catch (e) { cache = null }
  }
  const now = Date.now() / 1000
  if (cache && cache.id === id && now - cache.fetched < CACHE_TTL) return { payload: cache.payload, offline: false }
  try {
    const req = new Request(`https://api.github.com/gists/${encodeURIComponent(id)}`)
    req.headers = { Accept: 'application/vnd.github+json', 'User-Agent': 'ClaudeLimits-Scriptable' }
    req.timeoutInterval = 15
    const gist = await req.loadJSON()
    let payload = payloadFromGist(gist)
    const f = gist && gist.files && gist.files[GIST_FILE]
    if (!payload && f && f.truncated && f.raw_url) payload = await new Request(f.raw_url).loadJSON()
    if (!payload) throw new Error(gist && gist.message ? gist.message : 'no data')
    fm.writeString(cachePath, JSON.stringify({ id, fetched: now, payload }))
    return { payload, offline: false }
  } catch (e) {
    if (cache && cache.id === id) return { payload: cache.payload, offline: true }
    throw e
  }
}

// ---------- отрисовка ----------

const INK = () => Color.dynamic(new Color('#1D1B16'), new Color('#F4F1EA'))
const TRACK = () => Color.dynamic(new Color('#1D1B16', 0.10), new Color('#F4F1EA', 0.16))
const levelColor = (w) => new Color(COLORS[w.level])

function bar(used, width, height, color) {
  const ctx = new DrawContext()
  ctx.size = new Size(width, height)
  ctx.opaque = false
  ctx.respectScreenScale = true
  const r = height / 2
  const track = new Path()
  track.addRoundedRect(new Rect(0, 0, width, height), r, r)
  ctx.addPath(track)
  ctx.setFillColor(TRACK())
  ctx.fillPath()
  const w = Math.max(used > 0 ? height : 0, (width * used) / 100)
  if (w > 0) {
    const fill = new Path()
    fill.addRoundedRect(new Rect(0, 0, w, height), r, r)
    ctx.addPath(fill)
    ctx.setFillColor(color || new Color(COLORS[level(used)]))
    ctx.fillPath()
  }
  return ctx.getImage()
}

// Кольцо «сколько осталось»: дорожка по кругу и цветная дуга остатка со скруглёнными концами.
function ring(leftPct, size, lineWidth, color, trackColor) {
  const ctx = new DrawContext()
  ctx.size = new Size(size, size)
  ctx.opaque = false
  ctx.respectScreenScale = true
  const c = size / 2
  const r = c - lineWidth / 2
  const stroke = (pts, col) => {
    const p = new Path()
    p.addLines(pts.map(([x, y]) => new Point(x, y)))
    ctx.addPath(p)
    ctx.setStrokeColor(col)
    ctx.setLineWidth(lineWidth)
    ctx.strokePath()
    ctx.setFillColor(col)
    for (const [x, y] of [pts[0], pts[pts.length - 1]]) {
      ctx.fillEllipse(new Rect(x - lineWidth / 2, y - lineWidth / 2, lineWidth, lineWidth))
    }
  }
  stroke(arcPoints(c, c, r, 1), trackColor || TRACK())
  if (leftPct > 0) stroke(arcPoints(c, c, r, leftPct / 100), color)
  return ctx.getImage()
}

function text(stack, value, font, color, opacity) {
  const el = stack.addText(value)
  el.font = font
  el.textColor = color || INK()
  if (opacity !== undefined) el.textOpacity = opacity
  el.lineLimit = 1
  el.minimumScaleFactor = 0.6
  return el
}

// Кольцо с процентом в центре (стек с картинкой-фоном).
function ringStack(parent, w, size, lineWidth, fontSize, color, trackColor) {
  const st = parent.addStack()
  st.size = new Size(size, size)
  st.backgroundImage = ring(w.left, size, lineWidth, color || levelColor(w), trackColor)
  st.centerAlignContent()
  st.layoutVertically()
  const row = st.addStack()
  row.addSpacer()
  text(row, `${w.left}%`, Font.boldRoundedSystemFont(fontSize), color && trackColor ? color : null)
  row.addSpacer()
  return st
}

function barRow(parent, w, width, t) {
  const head = parent.addStack()
  head.centerAlignContent()
  text(head, w.title, Font.mediumSystemFont(10), null, 0.65)
  head.addSpacer()
  text(head, `${w.left}%`, Font.boldRoundedSystemFont(11), levelColor(w))
  parent.addSpacer(3)
  const img = parent.addImage(bar(w.used, width, 5))
  img.imageSize = new Size(width, 5)
  if (w.countdownShort) {
    parent.addSpacer(2)
    text(parent, `${t.reset} ${w.countdownShort}`, Font.systemFont(9), null, 0.5)
  }
}

function header(parent, src, t, showAgo) {
  const h = parent.addStack()
  h.centerAlignContent()
  const dot = h.addText('●')
  dot.font = Font.systemFont(7)
  dot.textColor = new Color(src.key === 'code' ? '#D97757' : '#6A9BCC')
  h.addSpacer(4)
  text(h, src.name, Font.semiboldSystemFont(11))
  if (showAgo) {
    h.addSpacer()
    text(h, src.ago, Font.systemFont(9), src.stale ? new Color(COLORS.yellow) : null, src.stale ? 1 : 0.45)
  }
}

function emptyWidget(w, title, hint) {
  text(w, 'Claude', Font.boldSystemFont(13))
  w.addSpacer(6)
  text(w, title, Font.semiboldSystemFont(12))
  w.addSpacer(2)
  const h = w.addText(hint)
  h.font = Font.systemFont(10)
  h.textColor = INK()
  h.textOpacity = 0.6
  return w
}

// Квадрат 2×2: кольцо 5-часового окна, под ним неделя полоской.
function renderSmall(w, src, t) {
  w.setPadding(12, 12, 12, 12)
  header(w, src, t, false)
  w.addSpacer()
  const five = src.windows.find((x) => x.id === 'five_hour') || src.windows[0]
  const week = src.windows.find((x) => x !== five)
  const row = w.addStack()
  row.centerAlignContent()
  ringStack(row, five, 62, 7, 17)
  row.addSpacer(8)
  const info = row.addStack()
  info.layoutVertically()
  text(info, five.short, Font.semiboldSystemFont(12))
  text(info, t.left, Font.systemFont(9), null, 0.5)
  if (five.countdownShort) {
    info.addSpacer(3)
    text(info, five.countdownShort, Font.mediumSystemFont(10), levelColor(five))
  }
  w.addSpacer()
  if (week) barRow(w, week, 128, t)
  else text(w, `${t.updated} ${src.ago}`, Font.systemFont(9), null, 0.45)
}

// Прямоугольник 2×4: Claude Code и Claude Desktop рядом, у каждого кольцо 5 ч и полоска недели.
function renderWide(w, model, t) {
  w.setPadding(12, 14, 12, 14)
  const row = w.addStack()
  row.layoutHorizontally()
  const cols = model.sources.slice(0, 2)
  const colWidth = cols.length > 1 ? 136 : 290
  cols.forEach((src, i) => {
    if (i > 0) {
      row.addSpacer(10)
      const sep = row.addStack()
      sep.size = new Size(1, 120)
      sep.backgroundColor = TRACK()
      row.addSpacer(10)
    }
    const col = row.addStack()
    col.layoutVertically()
    col.size = new Size(colWidth, 0)
    header(col, src, t, true)
    col.addSpacer(8)
    const five = src.windows.find((x) => x.id === 'five_hour') || src.windows[0]
    const week = src.windows.find((x) => x !== five)
    const top = col.addStack()
    top.centerAlignContent()
    ringStack(top, five, 50, 6, 13)
    top.addSpacer(8)
    const info = top.addStack()
    info.layoutVertically()
    text(info, five.title, Font.semiboldSystemFont(11))
    if (five.countdownShort) text(info, `${t.reset} ${five.countdownShort}`, Font.systemFont(9), null, 0.55)
    top.addSpacer()
    col.addSpacer(8)
    if (week) barRow(col, week, colWidth, t)
    col.addSpacer()
  })
  if (cols.length === 1) row.addSpacer()
}

// Экран блокировки: монохромные варианты (iOS сама окрашивает их под обои).
function renderAccessory(w, src, family, t) {
  const five = src.windows.find((x) => x.id === 'five_hour') || src.windows[0]
  const week = src.windows.find((x) => x !== five)
  const white = Color.white()
  if (family === 'accessoryCircular') {
    w.addAccessoryWidgetBackground = true
    w.setPadding(0, 0, 0, 0)
    const row = w.addStack()
    row.addSpacer()
    const st = row.addStack()
    st.size = new Size(60, 60)
    st.backgroundImage = ring(five.left, 60, 5, white, new Color('#FFFFFF', 0.25))
    st.layoutVertically()
    st.centerAlignContent()
    const a = st.addStack(); a.addSpacer(); text(a, `${five.left}`, Font.boldRoundedSystemFont(19), white); a.addSpacer()
    const b = st.addStack(); b.addSpacer(); text(b, five.short, Font.mediumSystemFont(9), white, 0.7); b.addSpacer()
    row.addSpacer()
  } else if (family === 'accessoryInline') {
    text(w, `✳︎ ${five.left}% · ${five.countdownShort || t.done}${week ? ` · ${t.week1} ${week.left}%` : ''}`, Font.systemFont(12), white)
  } else {
    w.setPadding(0, 2, 0, 2)
    text(w, src.name, Font.boldSystemFont(12), white)
    w.addSpacer(3)
    for (const win of [five, week].filter(Boolean)) {
      const r = w.addStack()
      r.centerAlignContent()
      text(r, win.short, Font.mediumSystemFont(11), white, 0.8)
      r.addSpacer(4)
      const img = r.addImage(bar(win.used, 70, 5, white))
      img.imageSize = new Size(70, 5)
      r.addSpacer(4)
      text(r, `${win.left}%`, Font.boldRoundedSystemFont(11), white)
      r.addSpacer()
      w.addSpacer(2)
    }
    if (five.countdownShort) text(w, `${t.reset} ${five.countdownShort}`, Font.systemFont(10), white, 0.7)
  }
}

async function buildWidget() {
  const family = config.widgetFamily || 'medium'
  const t = strings(Device.language())
  const { id, source } = parseParameter(args.widgetParameter, GIST_ID)
  const w = new ListWidget()
  w.setPadding(12, 14, 12, 14)
  w.refreshAfterDate = new Date(Date.now() + 5 * 60 * 1000)
  const accessory = family.startsWith('accessory')
  if (!accessory) w.backgroundColor = Color.dynamic(new Color('#FAF8F3'), new Color('#1A1916'))
  if (!id) return emptyWidget(w, t.noId, t.noIdHint)

  let loaded
  try { loaded = await loadPayload(id) } catch (e) { return emptyWidget(w, t.noData, String(e.message || e)) }
  const model = buildModel(loaded.payload, Date.now() / 1000, Device.language())
  const src = pickSource(model, source)
  if (!src) return emptyWidget(w, t.noData, t.noDataHint)

  if (accessory) { renderAccessory(w, src, family, t); return w }
  if (family === 'small') renderSmall(w, src, t)
  else renderWide(w, source ? { sources: [src] } : model, t)
  if (loaded.offline) {
    w.addSpacer(2)
    text(w, t.offline, Font.systemFont(8), new Color(COLORS.yellow))
  }
  return w
}

async function main() {
  const widget = await buildWidget()
  if (config.runsInWidget || config.runsInAccessoryWidget) {
    Script.setWidget(widget)
  } else {
    await widget.presentMedium()
  }
  Script.complete()
}

if (typeof Script !== 'undefined') {
  await main()
} else if (typeof module !== 'undefined') {
  module.exports = { parseParameter, level, countdown, arcPoints, payloadFromGist, buildModel, pickSource, strings }
}
