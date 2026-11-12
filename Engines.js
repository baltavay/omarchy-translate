// Translation engines for the overlay.
//
// The requests are made from inside the shell process with XMLHttpRequest:
// there is no helper executable, so the text being translated never reaches a
// command line — a command line is readable by every local user through
// /proc/<pid>/cmdline, and so is everything on it, byte for byte.
//
// Engines, tried in order:
//   1. google    clients5.google.com/translate_a/t?client=dict-chrome-ex — the
//                keyless endpoint the Chrome dictionary extension talks to.
//                Fast, good quality.
//   2. mymemory  api.mymemory.translated.net/get — keyless, ~5k chars/day
//                anonymous, ~50k when a contact address is passed in
//                options.email.
// and, only when it is the chosen engine and a key is set, ahead of both:
//   0. deepl     the official DeepL API (api-free.deepl.com for ":fx" keys,
//                api.deepl.com otherwise). The key travels in the
//                Authorization header of a POST, never in a URL.
//
// Long text is chunked so no single request exceeds what an endpoint accepts,
// and the chunks are rejoined with the newlines they were split on.
//
// translate(options, onDone) -> handle
//
//   options.text     text to translate
//   options.from     source language code, "auto" to detect
//   options.to       target language code, never "auto"
//   options.engine   the engine to try first: "google" (default), "deepl" or
//                    "mymemory"
//   options.email    MyMemory contact address; "" to leave it out
//   options.deeplKey DeepL API key; without one DeepL is skipped
//   options.locale   POSIX locale ("en_GB.UTF-8"), to pick DeepL's English and
//                    Portuguese target variants; US and Brazilian otherwise
//   options.request  transport, (target, timeoutMs, onReply) -> {abort}, where
//                    target is a GET URL or {method, url, headers, body}.
//                    Defaults to plain XMLHttpRequest, which sets xhr.timeout
//                    but — on Quickshell's Qt — is not actually capped by it,
//                    so callers that need a wall clock pass their own (the
//                    overlay passes a Timer-backed one; tests pass a stub).
//
//   onDone(reply)    called at most once, with
//                      {ok: true,  text, engine, detected, skipped} or
//                      {ok: false, error, engine: "none", skipped}
//                    skipped lists the engines that were tried first and did
//                    not answer, as {engine, reason}, so a fallback is never
//                    silent. For rejected arguments onDone runs synchronously,
//                    before translate() returns the handle.
//   handle.cancel()  aborts the request in flight and silences onDone

.pragma library

var GOOGLE_URL = "https://clients5.google.com/translate_a/t"
var MYMEMORY_URL = "https://api.mymemory.translated.net/get"
var DEEPL_FREE_BASE = "https://api-free.deepl.com"
var DEEPL_PRO_BASE = "https://api.deepl.com"

// Chunk sizes are counted in UTF-16 code units — never fewer than the glyphs
// they cover, so an emoji-heavy chunk still fits where a bash `fold -w` one did.
var GOOGLE_CHUNK = 700    // per request: keeps even 4-byte glyphs inside URL limits
var MYMEMORY_CHUNK = 110  // MyMemory caps one request at 500 bytes; 110 fits in any script
var DEEPL_CHUNK = 20000   // a POST body; DeepL takes up to 128 KiB per request

var GOOGLE_TIMEOUT = 12000
var MYMEMORY_TIMEOUT = 15000
var DEEPL_TIMEOUT = 15000

var NO_ENGINE = "no engine answered — check the network or the daily rate limit"

// The knob is a preference, not a whitelist: the other engines still back it
// up. DeepL needs a key and spends a quota, so it only ever runs when chosen.
function engineOrder(preference, hasDeeplKey) {
  var pref = String(preference || "").toLowerCase()
  if (pref === "deepl" && hasDeeplKey) return ["deepl", "google", "mymemory"]
  return pref === "mymemory" ? ["mymemory", "google"] : ["google", "mymemory"]
}

// ------------------------------------------------------------------ deepl

// Free-plan keys end in ":fx" and are only accepted by the free endpoint.
function deeplBase(key) {
  return /:fx$/.test(String(key || "")) ? DEEPL_FREE_BASE : DEEPL_PRO_BASE
}

function deeplHeaders(key) {
  return { "Authorization": "DeepL-Auth-Key " + String(key || "") }
}

// Table code -> DeepL source code: the bare language, no variant. "" for auto.
function deeplSource(code) {
  switch (code) {
    case "auto": return ""
    case "zh-CN": case "zh-TW": return "ZH"
    case "no": return "NB"
  }
  return String(code).toUpperCase()
}

// Table code -> DeepL target code. English and Portuguese need a variant,
// taken from the locale's region when it names one.
function deeplTarget(code, locale) {
  var region = (String(locale || "").split(".")[0].split("@")[0].split(/[_-]/)[1] || "").toUpperCase()
  switch (code) {
    case "en": return region === "GB" || region === "IE" || region === "AU" || region === "NZ"
      || region === "IN" || region === "ZA" ? "EN-GB" : "EN-US"
    case "pt": return region === "PT" ? "PT-PT" : "PT-BR"
    case "zh-CN": return "ZH-HANS"
    case "zh-TW": return "ZH-HANT"
    case "no": return "NB"
  }
  return String(code).toUpperCase()
}

// DeepL's detected language -> table code.
function fromDeepl(code) {
  switch (String(code || "").toUpperCase()) {
    case "": return ""
    case "ZH": return "zh-CN"
    case "NB": return "no"
  }
  return String(code).toLowerCase()
}

// Why DeepL said no, in the words the status line shows.
function deeplReason(reply) {
  if (!reply || reply.error) return reply && reply.error ? String(reply.error) : "unreachable"
  switch (reply.status) {
    case 400: return "language not supported"
    case 401: case 403: return "key rejected"
    case 429: return "too many requests"
    case 456: return "quota exceeded"
  }
  return reply.status >= 500 ? "unavailable" : "error " + reply.status
}

// A GET of an authenticated DeepL endpoint (usage, used to check a key), as a
// target for the same transports translate() uses.
function deeplGet(key, path) {
  return { method: "GET", url: deeplBase(key) + path, headers: deeplHeaders(key) }
}

// /v2/usage -> {ok, used, limit}; on failure {ok: false, reason}.
function parseDeeplUsage(reply) {
  if (!httpOk(reply)) return { ok: false, reason: deeplReason(reply) }
  var parsed = null
  try { parsed = JSON.parse(String(reply.body || "")) } catch (e) { return { ok: false, reason: "bad answer" } }
  if (!parsed || typeof parsed.character_count !== "number" || typeof parsed.character_limit !== "number")
    return { ok: false, reason: "bad answer" }
  return { ok: true, used: parsed.character_count, limit: parsed.character_limit }
}

// Codes are Google's; fold the legacy aliases the same way the endpoints do.
function normalizeLanguage(code) {
  switch (String(code || "")) {
    case "": case "auto": case "detect": return "auto"
    case "zh": case "zh-CN": case "zh-cn": case "zh-Hans": return "zh-CN"
    case "zh-TW": case "zh-tw": case "zh-Hant": return "zh-TW"
    case "he": case "iw": return "he"
    case "no": case "nb": return "no"
  }
  return /^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?$/.test(String(code || "")) ? String(code) : ""
}

// --------------------------------------------------------------- chunking

// One folded line, mirroring `fold -s -w width`: break after the last blank
// inside the window so words survive, and mid-word only when there is none.
// Tabs are treated as ordinary characters, which can only fold earlier than
// `fold` would, never later.
function foldLine(line, width) {
  var pieces = []
  var rest = line
  while (rest.length > width) {
    var cut = rest.lastIndexOf(" ", width - 1)
    if (cut < 0) cut = width - 1
    pieces.push(rest.slice(0, cut + 1))
    rest = rest.slice(cut + 1)
  }
  pieces.push(rest)
  return pieces
}

// Fold every line, then pack folded lines back together while they fit, which
// is what keeps a paragraph in one request instead of one request per line.
function chunkText(text, width) {
  var lines = String(text === undefined || text === null ? "" : text).split("\n")
  var folded = []
  for (var i = 0; i < lines.length; i++) {
    var pieces = foldLine(lines[i], width)
    for (var j = 0; j < pieces.length; j++) folded.push(pieces[j])
  }

  var chunks = []
  var buf = ""
  for (var k = 0; k < folded.length; k++) {
    var line = folded[k]
    if (buf === "") buf = line
    else if (buf.length + 1 + line.length <= width) buf = buf + "\n" + line
    else { chunks.push(buf); buf = line }
  }
  if (buf !== "") chunks.push(buf)
  return chunks
}

// --------------------------------------------------------------- requests

function requestUrl(engine, chunk, from, to, email) {
  var q = encodeURIComponent(chunk)
  if (engine === "mymemory") {
    var pair = from === "auto" ? "autodetect|" + to : from + "|" + to
    var url = MYMEMORY_URL + "?q=" + q + "&langpair=" + encodeURIComponent(pair)
    return email === "" ? url : url + "&de=" + encodeURIComponent(email)
  }
  return GOOGLE_URL + "?client=dict-chrome-ex&sl=" + encodeURIComponent(from)
    + "&tl=" + encodeURIComponent(to) + "&q=" + q
}

// DeepL is a JSON POST with the key in a header; the others are plain GETs.
function requestTarget(engine, chunk, from, to, opts) {
  if (engine !== "deepl") return requestUrl(engine, chunk, from, to, String(opts.email || ""))
  var body = { text: [chunk], target_lang: deeplTarget(to, opts.locale) }
  var source = deeplSource(from)
  if (source !== "") body.source_lang = source
  var headers = deeplHeaders(opts.deeplKey)
  headers["Content-Type"] = "application/json"
  return {
    method: "POST",
    url: deeplBase(opts.deeplKey) + "/v2/translate",
    headers: headers,
    body: JSON.stringify(body)
  }
}

function engineTimeout(engine) {
  if (engine === "deepl") return DEEPL_TIMEOUT
  return engine === "mymemory" ? MYMEMORY_TIMEOUT : GOOGLE_TIMEOUT
}

function engineChunk(engine) {
  if (engine === "deepl") return DEEPL_CHUNK
  return engine === "mymemory" ? MYMEMORY_CHUNK : GOOGLE_CHUNK
}

// A transport target is a GET URL or {method, url, headers, body}.
function requestSpec(target) {
  return typeof target === "string" ? { method: "GET", url: target, headers: {} } : target
}

function xhrRequest(target, timeoutMs, onReply) {
  var spec = requestSpec(target)
  var xhr = new XMLHttpRequest()
  var settled = false

  function settle(reply) {
    if (settled) return
    settled = true
    onReply(reply)
  }

  xhr.open(spec.method || "GET", spec.url)
  var headers = spec.headers || {}
  for (var name in headers) xhr.setRequestHeader(name, headers[name])
  xhr.timeout = timeoutMs
  xhr.onreadystatechange = function() {
    if (xhr.readyState !== XMLHttpRequest.DONE) return
    if (xhr.status === 0) settle({ error: "unreachable" })
    else settle({ status: xhr.status, body: xhr.responseText })
  }
  xhr.onerror = function() { settle({ error: "unreachable" }) }
  xhr.onabort = function() { settle({ error: "cancelled" }) }
  xhr.ontimeout = function() { settle({ error: "timeout" }) }
  if (spec.body === undefined) xhr.send()
  else xhr.send(spec.body)

  return { abort: function() { xhr.abort() } }
}

// --------------------------------------------------------------- parsing

function httpOk(reply) {
  return !!reply && !reply.error && reply.status >= 200 && reply.status < 300
}

function parseGoogle(reply) {
  if (!httpOk(reply)) return { ok: false }
  var body = String(reply.body || "")
  if (body.charAt(0) !== "[") return { ok: false } // a blocked or malformed answer is an HTML page
  var parsed = null
  try { parsed = JSON.parse(body) } catch (e) { return { ok: false } }
  if (!parsed || parsed.length === 0) return { ok: false }

  var text = ""
  var detected = ""
  if (Array.isArray(parsed[0])) {
    // [["translated", "detected", …], …] — one entry per sentence. Anything
    // that is not a string is dropped rather than stringified: the answer is
    // untrusted network data, and "[object Object]" is not a translation.
    for (var i = 0; i < parsed.length; i++) {
      var entry = parsed[i]
      if (Array.isArray(entry)) { if (typeof entry[0] === "string") text += entry[0] }
      else if (typeof entry === "string") text += entry
    }
    if (typeof parsed[0][1] === "string") detected = parsed[0][1]
  } else {
    // ["translated"] — the shape the dictionary endpoint answers short input with.
    if (typeof parsed[0] !== "string") return { ok: false }
    text = parsed[0]
  }
  return { ok: true, text: text, detected: detected }
}

function parseMyMemory(reply) {
  if (!httpOk(reply)) return { ok: false }
  var parsed = null
  try { parsed = JSON.parse(String(reply.body || "")) } catch (e) { return { ok: false } }
  if (!parsed || Number(parsed.responseStatus) !== 200) return { ok: false }

  var data = parsed.responseData || {}
  var text = data.translatedText === undefined || data.translatedText === null
    ? "" : String(data.translatedText)
  if (text === "") return { ok: false }
  // MyMemory reports a spent quota inside the translated text itself.
  if (text.indexOf("MYMEMORY WARNING") !== -1
      || text.indexOf("YOU USED ALL AVAILABLE FREE TRANSLATIONS") !== -1) return { ok: false }

  var detected = data.detectedLanguage ? String(data.detectedLanguage) : ""
  return { ok: true, text: text, detected: detected }
}

// {"translations": [{"detected_source_language": "EN", "text": "…"}]}
function parseDeepl(reply) {
  if (!httpOk(reply)) return { ok: false, reason: deeplReason(reply) }
  var parsed = null
  try { parsed = JSON.parse(String(reply.body || "")) } catch (e) { return { ok: false, reason: "bad answer" } }
  var first = parsed && Array.isArray(parsed.translations) ? parsed.translations[0] : null
  if (!first || typeof first.text !== "string") return { ok: false, reason: "bad answer" }
  return { ok: true, text: first.text, detected: fromDeepl(first.detected_source_language) }
}

function parseChunk(engine, reply) {
  if (engine === "deepl") return parseDeepl(reply)
  return engine === "mymemory" ? parseMyMemory(reply) : parseGoogle(reply)
}

// ----------------------------------------------------------------- driver

function translate(options, onDone) {
  var opts = options || {}
  var state = { cancelled: false, done: false, current: null }
  var engines = engineOrder(opts.engine, String(opts.deeplKey || "") !== "")
  var skipped = []

  function finish(reply) {
    if (state.cancelled || state.done) return
    state.done = true
    onDone(reply)
  }

  var from = normalizeLanguage(opts.from)
  var to = normalizeLanguage(opts.to)
  var text = String(opts.text === undefined || opts.text === null ? "" : opts.text)

  if (from === "") { finish({ ok: false, engine: "none", error: "unsupported language code: " + opts.from }); return handle() }
  if (to === "") { finish({ ok: false, engine: "none", error: "unsupported language code: " + opts.to }); return handle() }
  if (to === "auto") { finish({ ok: false, engine: "none", error: "'auto' is not a valid target language" }); return handle() }
  if (text === "") { finish({ ok: true, text: "", engine: "none", detected: from }); return handle() }
  if (from === to) { finish({ ok: true, text: text, engine: "none", detected: from }); return handle() }

  runEngine(0)
  return handle()

  function handle() {
    return {
      cancel: function() {
        if (state.done || state.cancelled) return
        state.cancelled = true
        var current = state.current
        state.current = null
        if (current && current.abort) current.abort()
      }
    }
  }

  function runEngine(index) {
    if (state.cancelled || state.done) return
    if (index >= engines.length) {
      finish({ ok: false, engine: "none", error: NO_ENGINE, skipped: skipped })
      return
    }

    var engine = engines[index]
    var chunks = chunkText(text, engineChunk(engine))
    var out = []
    var detected = ""
    var at = 0

    // Chunks go out one at a time: a later one would only queue behind an
    // endpoint that is already refusing us.
    function next() {
      if (state.cancelled || state.done) return
      if (at >= chunks.length) {
        finish({ ok: true, text: out.join("\n"), engine: engine, detected: detected || from, skipped: skipped })
        return
      }

      var chunk = chunks[at]
      at += 1
      if (chunk === "") { out.push(""); next(); return }

      var request = opts.request || xhrRequest
      var answered = false
      var onReply = function(reply) {
        answered = true
        state.current = null
        if (state.cancelled || state.done) return
        var parsed = parseChunk(engine, reply)
        if (!parsed.ok) {
          giveUp(parsed.reason || (reply && reply.error)
            || (reply && reply.status && !httpOk(reply) ? "error " + reply.status : "bad answer"))
          return
        }
        out.push(parsed.text)
        if (!detected && parsed.detected) detected = parsed.detected
        next()
      }
      try {
        state.current = request(requestTarget(engine, chunk, from, to, opts),
          engineTimeout(engine), onReply)
      } catch (e) {
        // A transport that cannot even start is just another engine that failed.
        if (!answered) {
          state.current = null
          giveUp("could not start")
        }
      }
    }

    // Hand over to the next engine, keeping the reason this one gave up.
    function giveUp(reason) {
      skipped.push({ engine: engine, reason: String(reason) })
      runEngine(index + 1)
    }

    next()
  }
}
