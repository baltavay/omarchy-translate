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
//
// Long text is chunked so no single request exceeds what an endpoint accepts,
// and the chunks are rejoined with the newlines they were split on.
//
// translate(options, onDone) -> handle
//
//   options.text     text to translate
//   options.from     source language code, "auto" to detect
//   options.to       target language code, never "auto"
//   options.engine   the engine to try first: "google" (default) or "mymemory"
//   options.email    MyMemory contact address; "" to leave it out
//   options.request  transport, (url, timeoutMs, onReply) -> {abort}. Defaults
//                    to plain XMLHttpRequest, which sets xhr.timeout but — on
//                    Quickshell's Qt — is not actually capped by it, so callers
//                    that need a wall clock pass their own (the overlay passes
//                    a Timer-backed one; tests pass a stub).
//
//   onDone(reply)    called at most once, with
//                      {ok: true,  text, engine, detected} or
//                      {ok: false, error, engine: "none"}
//                    For rejected arguments it runs synchronously, before
//                    translate() returns the handle.
//   handle.cancel()  aborts the request in flight and silences onDone

.pragma library

var GOOGLE_URL = "https://clients5.google.com/translate_a/t"
var MYMEMORY_URL = "https://api.mymemory.translated.net/get"

// Chunk sizes are counted in UTF-16 code units — never fewer than the glyphs
// they cover, so an emoji-heavy chunk still fits where a bash `fold -w` one did.
var GOOGLE_CHUNK = 700    // per request: keeps even 4-byte glyphs inside URL limits
var MYMEMORY_CHUNK = 110  // MyMemory caps one request at 500 bytes; 110 fits in any script

var GOOGLE_TIMEOUT = 12000
var MYMEMORY_TIMEOUT = 15000

var NO_ENGINE = "no engine answered — check the network or the daily rate limit"

// The knob is a preference, not a whitelist: the other engine still backs it up.
function engineOrder(preference) {
  return String(preference || "").toLowerCase() === "mymemory"
    ? ["mymemory", "google"]
    : ["google", "mymemory"]
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

function engineTimeout(engine) {
  return engine === "mymemory" ? MYMEMORY_TIMEOUT : GOOGLE_TIMEOUT
}

function xhrRequest(url, timeoutMs, onReply) {
  var xhr = new XMLHttpRequest()
  var settled = false

  function settle(reply) {
    if (settled) return
    settled = true
    onReply(reply)
  }

  xhr.open("GET", url)
  xhr.timeout = timeoutMs
  xhr.onreadystatechange = function() {
    if (xhr.readyState !== XMLHttpRequest.DONE) return
    if (xhr.status === 0) settle({ error: "unreachable" })
    else settle({ status: xhr.status, body: xhr.responseText })
  }
  xhr.onerror = function() { settle({ error: "unreachable" }) }
  xhr.onabort = function() { settle({ error: "cancelled" }) }
  xhr.ontimeout = function() { settle({ error: "timeout" }) }
  xhr.send()

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

function parseChunk(engine, reply) {
  return engine === "mymemory" ? parseMyMemory(reply) : parseGoogle(reply)
}

// ----------------------------------------------------------------- driver

function translate(options, onDone) {
  var opts = options || {}
  var state = { cancelled: false, done: false, current: null }
  var engines = engineOrder(opts.engine)

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
      finish({ ok: false, engine: "none", error: NO_ENGINE })
      return
    }

    var engine = engines[index]
    var chunks = chunkText(text, engine === "mymemory" ? MYMEMORY_CHUNK : GOOGLE_CHUNK)
    var out = []
    var detected = ""
    var at = 0

    // Chunks go out one at a time: a later one would only queue behind an
    // endpoint that is already refusing us.
    function next() {
      if (state.cancelled || state.done) return
      if (at >= chunks.length) {
        finish({ ok: true, text: out.join("\n"), engine: engine, detected: detected || from })
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
        if (!parsed.ok) { runEngine(index + 1); return }
        out.push(parsed.text)
        if (!detected && parsed.detected) detected = parsed.detected
        next()
      }
      try {
        state.current = request(requestUrl(engine, chunk, from, to, String(opts.email || "")),
          engineTimeout(engine), onReply)
      } catch (e) {
        // A transport that cannot even start is just another engine that failed.
        if (!answered) {
          state.current = null
          runEngine(index + 1)
        }
      }
    }

    next()
  }
}
