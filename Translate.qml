import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui as Ui
import "Languages.js" as Languages
import "Engines.js" as Engines

// Keyboard-first translation overlay for omarchy-shell.
//
// SUPER + SHIFT + K summons it. Two panes (source, translation), a language
// chip per pane, and a filterable language picker. Everything the mouse can do
// has a key: Ctrl+Enter translate, Ctrl+S swap, Ctrl+L pick the source
// language, Ctrl+Shift+L the target, Ctrl+Shift+C copy the result,
// Ctrl+Shift+V translate the clipboard, Ctrl+Shift+X clear, Ctrl+P toggle
// auto-translate, Ctrl+E switch engine (Google / DeepL), Ctrl+Shift+E the
// DeepL key, F1 the shortcut list, Esc close.
//
// The overlay lives inside the long-lived omarchy-shell process and keeps its
// panes, chosen languages, and in-flight request across summons (manifest
// keepLoaded). Engines.js does the talking with XMLHttpRequest inside that same
// process: no helper is spawned, so neither the text being translated nor the
// translation ever lands on a command line, where /proc/<pid>/cmdline would
// hand it to every local user. A hung request is aborted from here.
Item {
  id: root

  // Injected by the shell's panel loader.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "io.github.baltavay.translate"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy"
  readonly property string statePath: stateDir + "/translate.json"

  // Which engine goes first, and the MyMemory address that lifts its quota.
  // The engine knob only seeds the choice until one is saved from the overlay.
  readonly property string enginePreference: Quickshell.env("OMARCHY_TRANSLATE_ENGINE") || ""
  readonly property string contactEmail: Quickshell.env("OMARCHY_TRANSLATE_EMAIL") || ""
  // DeepL's English and Portuguese targets need a variant; the region decides.
  readonly property string localeName: Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || ""
  // The DeepL API key lives in its own file, mode 600, next to the state but
  // never inside it, and outside ~/.config, which often ends up in dotfiles.
  readonly property string deeplKeyPath: stateDir + "/translate-deepl.key"

  // ---------------------------------------------------------------- state

  property bool opened: false
  property string sourceLang: "en"
  property string targetLang: "ru"
  property string sourceText: ""
  property string resultText: ""
  property bool autoTranslate: true

  property string engine: ""
  property string detectedLang: ""
  property string status: ""
  property string errorText: ""
  property bool busy: false
  property bool copied: false
  property bool showHelp: false

  // "google", "deepl" or "mymemory": the engine tried first. DeepL only runs
  // with a key; without one Google answers and the chip says so.
  property string engineChoice: {
    var pref = String(root.enginePreference).toLowerCase()
    return pref === "deepl" || pref === "mymemory" ? pref : "google"
  }
  property string deeplKey: ""
  property real deeplUsed: -1
  property real deeplLimit: -1
  property bool keyPanelOpen: false
  property bool keyChecking: false
  property string keyStatus: ""
  property int sideSeq: 0
  property var sideHandle: null
  readonly property bool deeplActive: engineChoice === "deepl" && deeplKey !== ""
  readonly property string engineLabel: engineChoice === "deepl"
    ? (deeplKey === "" ? "DeepL · no key" : deeplLimit > 0
        ? "DeepL · " + shortCount(deeplUsed) + " / " + shortCount(deeplLimit) : "DeepL")
    : engineChoice === "mymemory" ? "MyMemory" : "Google"

  property bool pickerOpen: false
  property string pickerSide: "source"
  property string pickerQuery: ""
  property int pickerIndex: 0
  property var pickerResults: []

  property int requestSeq: 0
  property int pendingSeq: -1
  property bool queuedTranslate: false
  property var activeRequest: null
  property real startedAt: 0
  property string translatedSource: ""
  property bool syncingText: false

  readonly property var sourceLanguage: Languages.byCode(sourceLang)
  readonly property var targetLanguage: Languages.byCode(targetLang)
  readonly property string sourceChip: Languages.chip(sourceLang)
  readonly property string targetChip: Languages.chip(targetLang)

  // ---------------------------------------------------------------- theme

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color border: Color.menu.border
  readonly property var cardBorder: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property var normalPaneBorder: Border.controlSpec("normal", foreground, accent)
  readonly property var focusPaneBorder: Border.controlSpec("focus", foreground, accent)
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string chromeFont: Style.font.menuFamily
  readonly property string bodyFont: Style.font.family
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int contentSpacing: Style.spacing.md
  readonly property int paneGap: Style.spacing.panelGap
  readonly property int panePadding: Style.spacing.md
  readonly property int headerHeight: Math.max(Style.space(30), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int footerHeight: Math.max(Style.space(30), Style.font.body + Style.spacing.controlPaddingY * 2)
  readonly property int chipHeight: Math.max(Style.space(24), Style.font.body + Style.spacing.controlPaddingY * 2)
  readonly property int cardWidth: Math.min(Style.space(1040), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(640), panel.height - Style.gapsOut * 2)
  readonly property int paneWidth: Math.round((cardWidth - contentMargin * 2 - paneGap * 2 - swapColumn.width) / 2)

  readonly property var helpRows: [
    { keys: "Ctrl+Enter", action: "translate now" },
    { keys: "Ctrl+S", action: "swap languages and panes" },
    { keys: "Ctrl+L", action: "pick source language" },
    { keys: "Ctrl+Shift+L", action: "pick target language" },
    { keys: "Ctrl+1 / Ctrl+2", action: "focus source / translation" },
    { keys: "Ctrl+Shift+C", action: "copy the translation" },
    { keys: "Ctrl+Shift+V", action: "translate the clipboard" },
    { keys: "Ctrl+Shift+X", action: "clear both panes" },
    { keys: "Ctrl+P", action: "toggle auto-translate" },
    { keys: "Ctrl+E", action: "switch engine: Google / DeepL" },
    { keys: "Ctrl+Shift+E", action: "set or forget the DeepL API key" },
    { keys: "Ctrl+A / C / V", action: "select all / copy / paste" },
    { keys: "Tab / Shift+Tab", action: "move focus between panes" },
    { keys: "Esc", action: "close" }
  ]

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    root.opened = true
    root.pickerOpen = false
    root.showHelp = false
    var payload = null
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = null }
    if (payload && typeof payload === "object") {
      if (typeof payload.source === "string" && Languages.exists(payload.source))
        root.setLanguage("source", payload.source, true)
      if (typeof payload.target === "string" && Languages.exists(payload.target))
        root.setLanguage("target", payload.target, true)
      if (typeof payload.text === "string") {
        root.setSourceText(payload.text, true)
      }
    }
    // Reading the usage spends no quota; it keeps the chip's count current.
    if (root.deeplActive) root.refreshUsage()
    Qt.callLater(function() { root.focusSource() })
  }

  function close() {
    root.opened = false
    root.pickerOpen = false
    root.showHelp = false
    root.closeKeyPanel()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // --------------------------------------------------------------- panes

  function setSourceText(value, immediate) {
    var next = String(value === undefined || value === null ? "" : value)
    if (sourceArea.text !== next) {
      root.syncingText = true
      sourceArea.text = next
      sourceArea.cursorPosition = sourceArea.length
      root.syncingText = false
    }
    root.sourceText = next
    if (immediate) {
      debounce.stop()
      root.translateNow(true)
    } else {
      root.sourceEdited()
    }
  }

  function setResultText(value) {
    var next = String(value === undefined || value === null ? "" : value)
    if (resultArea.text !== next) {
      root.syncingText = true
      resultArea.text = next
      resultArea.cursorPosition = 0
      root.syncingText = false
    }
    root.resultText = next
  }

  function sourceEdited() {
    if (!root.syncingText) root.sourceText = sourceArea.text
    if (root.sourceText.replace(/\s/g, "") === "") {
      debounce.stop()
      root.setResultText("")
      root.status = ""
      root.errorText = ""
      root.translatedSource = ""
      return
    }
    if (!root.autoTranslate) return
    if (root.sourceText === root.translatedSource) return
    debounce.restart()
  }

  function resultEdited() {
    if (!root.syncingText) root.resultText = resultArea.text
  }

  function focusSource() {
    sourceArea.forceActiveFocus()
    sourceArea.cursorPosition = sourceArea.length
  }

  function focusResult() {
    resultArea.forceActiveFocus()
  }

  function cycleFocus(direction) {
    if (sourceArea.activeFocus && direction > 0) root.focusResult()
    else if (resultArea.activeFocus && direction < 0) root.focusSource()
    else if (direction > 0) root.focusSource()
    else root.focusResult()
  }

  function clearAll() {
    debounce.stop()
    root.translatedSource = ""
    root.setSourceText("")
    root.setResultText("")
    root.status = ""
    root.errorText = ""
    root.focusSource()
  }

  function swap() {
    var from = root.sourceLang
    var to = root.targetLang

    if (from === "auto") {
      // Nothing concrete to translate from: pin the detected language instead,
      // and let the old target take over as the source.
      var detected = Languages.exists(root.detectedLang) ? root.detectedLang : "en"
      root.sourceLang = to
      root.targetLang = detected === to ? (to === "en" ? "ru" : "en") : detected
    } else {
      root.sourceLang = to
      root.targetLang = from === to ? "en" : from
    }

    // Each pane already holds the other language's text, so exchanging them
    // makes the swap instant instead of paying for an API round trip.
    var source = root.sourceText
    var result = root.resultText
    if (result.replace(/\s/g, "") !== "") {
      debounce.stop()
      root.setSourceText(result)
      root.setResultText(source)
      root.translatedSource = result
      root.status = "swapped"
      root.errorText = ""
    } else if (root.autoTranslate) {
      debounce.stop()
      root.translateNow(true)
    }
  }

  function toggleAuto() {
    root.autoTranslate = !root.autoTranslate
    if (root.autoTranslate) {
      if (root.sourceText.replace(/\s/g, "") !== "") {
        debounce.stop()
        root.translateNow(true)
      }
    } else {
      debounce.stop()
      root.status = "auto-translate off"
    }
  }

  function copyResult() {
    var text = root.resultText.replace(/\s/g, "") !== "" ? root.resultText : root.sourceText
    if (text.replace(/\s/g, "") === "") {
      root.status = "nothing to copy"
      return
    }
    root.writeClipboard(text)
    root.copied = true
    copyFlash.restart()
  }

  // wl-copy reads the text from stdin. Handing it over as an argument would
  // put it in the child's argv, readable by every local user while the process
  // lives; the pipe is private to the shell and wl-copy. A copy pressed while
  // one is still running is written by the process that starts when it exits,
  // because running stays true in between.
  function writeClipboard(text) {
    copyProc.payload = text
    copyProc.stdinEnabled = true
    copyProc.running = true
  }

  function pasteSource() {
    if (pasteProc.running) return
    pasteProc.running = true
  }

  // ----------------------------------------------------------- translate

  function translateNow(force) {
    var text = root.sourceText
    if (text.replace(/\s/g, "") === "") {
      root.setResultText("")
      root.status = ""
      return
    }
    if (root.sourceLang !== "auto" && root.sourceLang === root.targetLang) {
      root.setResultText(text)
      root.translatedSource = text
      root.status = "same language"
      root.errorText = ""
      return
    }
    if (!force && text === root.translatedSource) return
    if (root.busy) {
      root.queuedTranslate = true
      root.cancelFetch()
      return
    }
    root.startFetch(text)
  }

  // An XHR capped by a wall-clock Timer. A target is a GET URL or
  // {method, url, headers, body} (see Engines.js). Each Timer guards one
  // request at a time, held in its `request` slot.
  function timedXhr(target, timeoutMs, timer, onReply) {
    var spec = Engines.requestSpec(target)
    var xhr = new XMLHttpRequest()
    var settled = false
    var stopped = false
    var timedOut = false
    var handle = {
      abort: function() { stopped = true; xhr.abort() },
      timeOut: function() { timedOut = true; xhr.abort() }
    }

    function settle(reply) {
      if (settled) return
      settled = true
      if (timer.request === handle) {
        timer.request = null
        timer.stop()
      }
      onReply(reply)
    }

    xhr.open(spec.method || "GET", spec.url)
    var headers = spec.headers || {}
    for (var name in headers) xhr.setRequestHeader(name, headers[name])
    xhr.timeout = timeoutMs // honored where the engine supports it
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (xhr.status === 0) {
        // A dropped request reports status 0: say why it was dropped, when we know.
        settle({ error: timedOut ? "timeout" : stopped ? "cancelled" : "unreachable" })
      } else settle({ status: xhr.status, body: xhr.responseText })
    }
    xhr.onerror = function() { settle({ error: "unreachable" }) }
    xhr.onabort = function() { settle({ error: timedOut ? "timeout" : stopped ? "cancelled" : "unreachable" }) }

    timer.request = handle
    timer.interval = Math.max(1, timeoutMs)
    timer.restart()
    if (spec.body === undefined) xhr.send()
    else xhr.send(spec.body)
    return handle
  }

  // The transport Engines issues translations through. Only one is in flight
  // at a time (chunks go out one by one), so fetchTimeout alone guards them.
  function timedRequest(target, timeoutMs, onReply) {
    return root.timedXhr(target, timeoutMs, fetchTimeout, onReply)
  }

  // Requests beside a translation (checking a DeepL key, reading its usage)
  // get their own Timer, so they never cut short a translation in flight. A
  // newer one supersedes an older one, whose answer is then dropped.
  function sideRequest(target, timeoutMs, onReply) {
    root.abortSideRequest()
    var seq = root.sideSeq
    root.sideHandle = root.timedXhr(target, timeoutMs, sideTimeout, function(reply) {
      if (seq !== root.sideSeq) return
      root.sideHandle = null
      onReply(reply)
    })
  }

  function abortSideRequest() {
    root.sideSeq += 1
    var handle = root.sideHandle
    root.sideHandle = null
    if (handle) handle.abort()
  }

  function startFetch(text) {
    root.requestSeq += 1
    var seq = root.requestSeq
    root.pendingSeq = seq
    root.startedAt = Date.now()
    root.busy = true
    root.status = "translating…"
    root.errorText = ""
    root.activeRequest = Engines.translate({
      text: text,
      from: root.sourceLang,
      to: root.targetLang,
      engine: root.engineChoice,
      email: root.contactEmail,
      deeplKey: root.deeplKey,
      locale: root.localeName,
      request: root.timedRequest
    }, function(reply) {
      if (seq !== root.pendingSeq) return
      root.pendingSeq = -1
      root.activeRequest = null
      root.busy = false

      var fallbacks = root.fallbackNotes(reply.skipped)
      if (reply.ok !== true) {
        root.fail(String(reply.error || "translation failed")
          + (fallbacks.length ? " (" + fallbacks.join(", ") + ")" : ""))
        return
      }

      root.translatedSource = root.sourceText
      root.setResultText(String(reply.text || ""))
      root.engine = String(reply.engine || "")
      if (reply.detected) root.detectedLang = String(reply.detected)
      // DeepL bills the source characters; keep the chip's count close until
      // the next open reads the real figure.
      if (root.engine === "deepl" && root.deeplUsed >= 0) root.deeplUsed += text.length
      root.errorText = ""
      var parts = []
      if (root.engine && root.engine !== "none") parts.push(root.engine)
      parts.push((Date.now() - root.startedAt) + " ms")
      parts.push(root.sourceText.length + " chars")
      if (root.sourceLang === "auto" && root.detectedLang)
        parts.push("detected " + root.detectedLang)
      for (var i = 0; i < fallbacks.length; i++) parts.push(fallbacks[i])
      root.status = parts.join(" · ")
    })
  }

  // Why the engines ahead of the one that answered did not, for the status
  // line: a fallback from DeepL to Google should never pass unnoticed.
  function fallbackNotes(skipped) {
    var notes = []
    var list = Array.isArray(skipped) ? skipped : []
    for (var i = 0; i < list.length; i++) {
      var name = list[i].engine === "deepl" ? "DeepL" : String(list[i].engine)
      var note = name + ": " + list[i].reason
      if (list[i].engine === "deepl" && list[i].reason === "key rejected") note += " (Ctrl+Shift+E)"
      notes.push(note)
    }
    return notes
  }

  // ---------------------------------------------------------------- engine

  function shortCount(n) {
    if (n >= 1000000) return (Math.round(n / 100000) / 10) + "M"
    if (n >= 1000) return Math.round(n / 1000) + "k"
    return String(Math.max(0, Math.round(n)))
  }

  // Ctrl+E: Google <-> DeepL. Choosing DeepL without a key asks for one, and
  // DeepL becomes the engine only once it has accepted that key.
  function toggleEngine() {
    if (root.engineChoice === "deepl") { root.setEngine("google"); return }
    if (root.deeplKey === "") { root.openKeyPanel(); return }
    root.setEngine("deepl")
    root.refreshUsage()
  }

  function setEngine(name) {
    if (root.engineChoice === name) return
    root.engineChoice = name
    root.errorText = ""
    if (root.autoTranslate && root.sourceText.replace(/\s/g, "") !== "") {
      debounce.stop()
      root.translateNow(true)
    } else {
      root.status = (name === "deepl" ? "DeepL" : "Google") + " selected"
    }
  }

  function refreshUsage() {
    var key = root.deeplKey
    if (key === "") return
    root.sideRequest(Engines.deeplGet(key, "/v2/usage"), 10000, function(reply) {
      var usage = Engines.parseDeeplUsage(reply)
      if (!usage.ok || key !== root.deeplKey) return
      root.deeplUsed = usage.used
      root.deeplLimit = usage.limit
    })
  }

  // --------------------------------------------------------------- deepl key

  function openKeyPanel() {
    root.pickerOpen = false
    root.showHelp = false
    root.keyStatus = ""
    root.keyChecking = false
    keyInput.text = ""
    root.keyPanelOpen = true
    Qt.callLater(function() { keyInput.forceActiveFocus() })
  }

  function closeKeyPanel() {
    var wasOpen = root.keyPanelOpen
    root.keyPanelOpen = false
    root.keyChecking = false
    root.keyStatus = ""
    keyInput.text = ""
    if (wasOpen) {
      root.abortSideRequest()
      if (root.opened) root.focusSource()
    }
  }

  // A pasted key is checked against /v2/usage, which spends no quota, and is
  // kept only when DeepL accepts it.
  function submitKey(raw) {
    var key = String(raw || "").trim()
    if (key === "" || /\s/.test(key)) {
      root.keyStatus = "paste the whole key from deepl.com/your-account/keys"
      return
    }
    root.keyChecking = true
    root.keyStatus = "checking the key with DeepL…"
    root.sideRequest(Engines.deeplGet(key, "/v2/usage"), 10000, function(reply) {
      root.keyChecking = false
      var usage = Engines.parseDeeplUsage(reply)
      if (!usage.ok) {
        root.keyStatus = "DeepL: " + usage.reason
        return
      }
      root.saveKey(key)
      root.deeplUsed = usage.used
      root.deeplLimit = usage.limit
      root.closeKeyPanel()
      if (root.engineChoice === "deepl") root.status = "DeepL key saved"
      else root.setEngine("deepl")
    })
  }

  // The key goes to the writer on stdin, like the clipboard text to wl-copy:
  // never on a command line. umask 077 makes the file 600 from the start.
  function saveKey(key) {
    root.deeplKey = key
    keyWriter.payload = key
    keyWriter.stdinEnabled = true
    keyWriter.running = true
  }

  function forgetKey() {
    root.deeplKey = ""
    root.deeplUsed = -1
    root.deeplLimit = -1
    Quickshell.execDetached(["rm", "-f", root.deeplKeyPath])
    root.closeKeyPanel()
    if (root.engineChoice === "deepl") root.setEngine("google")
    root.status = "DeepL key forgotten"
  }

  function cancelFetch() {
    if (!root.busy) return
    root.pendingSeq = -1
    root.busy = false
    if (root.activeRequest) {
      root.activeRequest.cancel()
      root.activeRequest = null
    }
    if (root.queuedTranslate) {
      root.queuedTranslate = false
      root.translateNow(true)
    }
  }

  function fail(message) {
    root.busy = false
    root.status = ""
    root.errorText = String(message)
  }

  // -------------------------------------------------------- language picker

  function openPicker(side) {
    root.closeKeyPanel()
    root.pickerSide = side === "target" ? "target" : "source"
    root.pickerOpen = true
    root.showHelp = false
    root.pickerQuery = ""
    root.rebuildPicker("")
    Qt.callLater(function() { pickerSearch.forceActiveFocus() })
  }

  function closePicker() {
    root.pickerOpen = false
    root.focusSource()
  }

  function rebuildPicker(query) {
    root.pickerQuery = query
    var results = Languages.search(query)
    root.pickerResults = results
    var current = root.pickerSide === "target" ? root.targetLang : root.sourceLang
    var index = 0
    for (var i = 0; i < results.length; i++) {
      if (results[i].code === current) { index = i; break }
    }
    root.pickerIndex = index
    if (pickerList.count > 0) pickerList.positionViewAtIndex(index, ListView.Contain)
  }

  function movePicker(delta) {
    var count = root.pickerResults.length
    if (count === 0) return
    var next = root.pickerIndex + delta
    if (next < 0) next = 0
    if (next > count - 1) next = count - 1
    root.pickerIndex = next
    pickerList.positionViewAtIndex(next, ListView.Contain)
  }

  function applyPicker() {
    var entry = root.pickerResults[root.pickerIndex]
    if (!entry) { root.closePicker(); return }
    root.setLanguage(root.pickerSide, entry.code)
    root.closePicker()
    if (root.autoTranslate && root.sourceText.replace(/\s/g, "") !== "") {
      debounce.stop()
      root.translateNow(true)
    }
  }

  function setLanguage(side, code, quiet) {
    if (!Languages.exists(code)) return
    if (side === "target") {
      if (code === "auto") return
      if (!quiet && code === root.sourceLang && root.sourceLang !== "auto")
        root.sourceLang = root.targetLang
      root.targetLang = code
    } else {
      if (!quiet && code === root.targetLang) {
        root.targetLang = root.sourceLang === "auto" ? "en" : root.sourceLang
      }
      root.sourceLang = code
    }
    root.detectedLang = ""
  }

  // ------------------------------------------------------------ shortcuts

  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var plain = ctrl && !shift
      && (event.modifiers & Qt.AltModifier) === 0
      && (event.modifiers & Qt.MetaModifier) === 0

    if (event.key === Qt.Key_F1) { root.closeKeyPanel(); root.showHelp = !root.showHelp; return true }
    if (event.key === Qt.Key_Escape) {
      if (root.keyPanelOpen) root.closeKeyPanel()
      else if (root.pickerOpen) root.closePicker()
      else if (root.showHelp) root.showHelp = false
      else if (root.busy) root.cancelFetch()
      else root.dismiss()
      return true
    }
    if (ctrl && event.key === Qt.Key_Return) { debounce.stop(); root.translateNow(true); return true }
    if (ctrl && event.key === Qt.Key_Enter) { debounce.stop(); root.translateNow(true); return true }
    if (plain && event.key === Qt.Key_S) { root.swap(); return true }
    if (plain && event.key === Qt.Key_L) { root.openPicker("source"); return true }
    if (plain && event.key === Qt.Key_P) { root.toggleAuto(); return true }
    if (plain && event.key === Qt.Key_E) { root.toggleEngine(); return true }
    if (ctrl && shift && event.key === Qt.Key_E) { root.openKeyPanel(); return true }
    if (plain && event.key === Qt.Key_1) { if (root.pickerOpen) root.pickerSide = "source"; else root.focusSource(); return true }
    if (plain && event.key === Qt.Key_2) { if (root.pickerOpen) root.pickerSide = "target"; else root.focusResult(); return true }
    if (ctrl && shift && event.key === Qt.Key_L) { root.openPicker("target"); return true }
    if (ctrl && shift && event.key === Qt.Key_C) { root.copyResult(); return true }
    if (ctrl && shift && event.key === Qt.Key_V) { root.pasteSource(); return true }
    if (ctrl && shift && event.key === Qt.Key_X) { root.clearAll(); return true }
    if (event.key === Qt.Key_Tab) { root.cycleFocus(shift ? -1 : 1); return true }
    if (event.key === Qt.Key_Backtab) { root.cycleFocus(-1); return true }
    return false
  }

  // ------------------------------------------------------------- file i/o

  function loadState(raw) {
    var state = null
    try { state = JSON.parse(String(raw || "")) } catch (e) { state = null }
    if (!state || typeof state !== "object") return
    if (typeof state.source === "string" && Languages.exists(state.source) && state.source !== "auto")
      root.sourceLang = state.source
    if (typeof state.target === "string" && Languages.exists(state.target) && state.target !== "auto")
      root.targetLang = state.target
    if (typeof state.auto === "boolean") root.autoTranslate = state.auto
    if (state.engine === "google" || state.engine === "deepl" || state.engine === "mymemory")
      root.engineChoice = state.engine
  }

  function writeState() {
    stateFile.setText(JSON.stringify({
      version: 1,
      source: root.sourceLang,
      target: root.targetLang,
      auto: root.autoTranslate,
      engine: root.engineChoice
    }, null, 2) + "\n")
  }

  onSourceLangChanged: stateSave.restart()
  onTargetLangChanged: stateSave.restart()
  onAutoTranslateChanged: stateSave.restart()
  onEngineChoiceChanged: stateSave.restart()

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", root.stateDir])
    root.rebuildPicker("")
  }

  Timer {
    id: debounce
    interval: 600
    repeat: false
    onTriggered: root.translateNow(false)
  }

  Timer {
    id: stateSave
    interval: 400
    repeat: false
    onTriggered: root.writeState()
  }

  // The wall clock for a request in flight. Quickshell's XMLHttpRequest
  // accepts xhr.timeout but never enforces it — a socket that accepts the
  // connection and goes silent hangs the request forever — so the transport
  // below arms this Timer and aborts when it fires, the way `curl --max-time`
  // used to.
  Timer {
    id: fetchTimeout
    property var request: null
    repeat: false
    onTriggered: {
      var pending = fetchTimeout.request
      fetchTimeout.request = null
      if (pending) pending.timeOut()
    }
  }

  // The same wall clock for side requests (a DeepL key check, its usage).
  Timer {
    id: sideTimeout
    property var request: null
    repeat: false
    onTriggered: {
      var pending = sideTimeout.request
      sideTimeout.request = null
      if (pending) pending.timeOut()
    }
  }

  Timer {
    id: copyFlash
    interval: 1400
    repeat: false
    onTriggered: root.copied = false
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
  }

  // Missing until a key is saved; a load failure then just means "no key".
  FileView {
    id: deeplKeyFile
    path: root.deeplKeyPath
    printErrors: false
    onLoaded: root.deeplKey = String(text() || "").trim()
  }

  Process {
    id: keyWriter
    property string payload: ""
    command: ["sh", "-c", "umask 077 && mkdir -p \"$1\" && rm -f \"$2.tmp\" && cat > \"$2.tmp\" && mv -f \"$2.tmp\" \"$2\"",
      "sh", root.stateDir, root.deeplKeyPath]
    stdinEnabled: false
    onStarted: {
      write(payload)
      payload = ""
      // Closing stdin ends cat's input once the key is out.
      stdinEnabled = false
    }
  }

  // The translation itself needs no process at all (see Engines.js); this is
  // only the clipboard writer, and it takes the text on stdin.
  Process {
    id: copyProc
    property string payload: ""
    command: ["wl-copy", "--type", "text/plain"]
    stdinEnabled: false
    onStarted: {
      write(payload)
      payload = ""
      // Closes stdin — after the queued bytes have gone out — so wl-copy sees
      // the end of its input and takes over the clipboard.
      stdinEnabled = false
    }
  }

  Process {
    id: pasteProc
    command: ["wl-paste", "--no-newline", "--type", "text"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var pasted = String(text || "")
        if (pasted.replace(/\s/g, "") === "") root.status = "clipboard has no text"
        else root.setSourceText(pasted, true)
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) root.status = "clipboard has no text"
    }
  }

  // ---------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-translate"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Ui.BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.cardBorder
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.handleKey(event)) event.accepted = true
        }

        Column {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: root.contentSpacing

          // ------------------------------------------------------- header
          Item {
            id: header
            width: parent.width
            height: root.headerHeight

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.controlGap

              Text {
                textFormat: Text.PlainText
                text: "󰗊"
                color: root.accent
                font.family: root.chromeFont
                font.pixelSize: Style.font.iconLarge
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: "Translate"
                color: root.foreground
                font.family: root.chromeFont
                font.pixelSize: Style.font.heading
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.controlGap

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, header.width * 0.55)
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.errorText !== "" ? root.errorText : root.status
                color: root.errorText !== "" ? root.urgent : (root.copied ? root.accent : root.muted)
                font.family: root.chromeFont
                font.pixelSize: Style.font.bodySmall
              }

              Ui.Button {
                anchors.verticalCenter: parent.verticalCenter
                text: root.engineLabel
                tooltipText: "Ctrl+E — switch engine (Google / DeepL) · Ctrl+Shift+E — DeepL key"
                bordered: true
                selected: root.keyPanelOpen
                fontSize: Style.font.bodySmall
                fontFamily: root.chromeFont
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.xxs
                onClicked: root.toggleEngine()
              }
            }
          }

          // ---------------------------------------------- panes / picker
          Item {
            width: parent.width
            height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

            Row {
              anchors.fill: parent
              spacing: root.paneGap
              visible: !root.pickerOpen && !root.showHelp && !root.keyPanelOpen

              // source pane
              Ui.BorderSurface {
                id: sourcePane
                width: root.paneWidth
                height: parent.height
                radius: root.cornerRadius
                color: Style.controlFill(sourceArea.activeFocus, false, root.foreground, root.accent)
                borderSpec: sourceArea.activeFocus ? root.focusPaneBorder : root.normalPaneBorder
                padding: root.panePadding

                Item {
                  anchors.fill: parent
                  anchors.topMargin: sourcePane.contentTopInset
                  anchors.rightMargin: sourcePane.contentRightInset
                  anchors.bottomMargin: sourcePane.contentBottomInset
                  anchors.leftMargin: sourcePane.contentLeftInset

                  Row {
                    id: sourceHeader
                    width: parent.width
                    height: root.chipHeight
                    spacing: Style.spacing.controlGap

                    Ui.Button {
                      id: sourceChipButton
                      text: root.sourceChip + " ▾"
                      tooltipText: root.sourceLanguage ? root.sourceLanguage.name : root.sourceChip
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.chromeFont
                      horizontalPadding: Style.spacing.controlPaddingX
                      verticalPadding: Style.spacing.xxs
                      onClicked: root.openPicker("source")
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      visible: root.sourceLang === "auto" && root.detectedLang !== ""
                      text: "detected " + root.detectedLang
                      color: root.muted
                      font.family: root.chromeFont
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Flickable {
                    id: sourceFlick
                    anchors.top: sourceHeader.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.topMargin: Style.spacing.controlGap
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    contentWidth: width
                    contentHeight: Math.max(height, sourceArea.contentHeight + Style.space(4))

                    TextEdit {
                      id: sourceArea
                      width: sourceFlick.width
                      wrapMode: TextEdit.Wrap
                      selectByMouse: true
                      persistentSelection: true
                      textFormat: TextEdit.PlainText
                      color: root.foreground
                      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                      selectedTextColor: root.foreground
                      font.family: root.bodyFont
                      font.pixelSize: Style.font.body
                      onTextChanged: root.sourceEdited()
                      onCursorRectangleChanged: {
                        var rect = cursorRectangle
                        if (rect.y < sourceFlick.contentY) sourceFlick.contentY = rect.y
                        else if (rect.y + rect.height > sourceFlick.contentY + sourceFlick.height)
                          sourceFlick.contentY = rect.y + rect.height - sourceFlick.height
                      }
                    }

                    Text {
                      x: 0
                      y: 0
                      enabled: false
                      visible: sourceArea.text === ""
                      textFormat: Text.PlainText
                      text: "Type or paste text — translation follows as you type"
                      color: root.muted
                      opacity: 0.7
                      font.family: root.bodyFont
                      font.pixelSize: Style.font.body
                    }

                    MouseArea {
                      anchors.fill: parent
                      acceptedButtons: Qt.NoButton
                      onWheel: function(wheel) {
                        var limit = Math.max(0, sourceFlick.contentHeight - sourceFlick.height)
                        sourceFlick.contentY = Math.max(0, Math.min(limit, sourceFlick.contentY - wheel.angleDelta.y))
                      }
                    }

                    Rectangle {
                      readonly property real ratio: sourceFlick.visibleArea.heightRatio
                      visible: sourceFlick.contentHeight > sourceFlick.height + 1
                      width: Style.space(3)
                      radius: width / 2
                      color: Util.alpha(root.foreground, 0.25)
                      x: sourceFlick.width - width - Style.space(2)
                      y: sourceFlick.visibleArea.yPosition * sourceFlick.height
                      height: Math.max(Style.space(12), ratio * sourceFlick.height)
                    }
                  }
                }
              }

              // swap
              Item {
                id: swapColumn
                width: Style.space(36)
                height: parent.height

                Ui.Button {
                  anchors.verticalCenter: parent.verticalCenter
                  width: swapColumn.width
                  height: root.chipHeight
                  iconText: "⇄"
                  iconSize: Style.font.iconLarge
                  tooltipText: "Swap languages (Ctrl+S)"
                  bordered: true
                  fontFamily: root.chromeFont
                  onClicked: root.swap()
                }
              }

              // result pane
              Ui.BorderSurface {
                id: resultPane
                width: root.paneWidth
                height: parent.height
                radius: root.cornerRadius
                color: Style.controlFill(resultArea.activeFocus, false, root.foreground, root.accent)
                borderSpec: resultArea.activeFocus ? root.focusPaneBorder : root.normalPaneBorder
                padding: root.panePadding

                Item {
                  anchors.fill: parent
                  anchors.topMargin: resultPane.contentTopInset
                  anchors.rightMargin: resultPane.contentRightInset
                  anchors.bottomMargin: resultPane.contentBottomInset
                  anchors.leftMargin: resultPane.contentLeftInset

                  Row {
                    id: resultHeader
                    width: parent.width
                    height: root.chipHeight
                    spacing: Style.spacing.controlGap

                    Ui.Button {
                      text: root.targetChip + " ▾"
                      tooltipText: root.targetLanguage ? root.targetLanguage.name : root.targetChip
                      bordered: true
                      fontSize: Style.font.bodySmall
                      fontFamily: root.chromeFont
                      horizontalPadding: Style.spacing.controlPaddingX
                      verticalPadding: Style.spacing.xxs
                      onClicked: root.openPicker("target")
                    }

                    Ui.Button {
                      text: root.copied ? "copied" : "copy"
                      tooltipText: "Copy the translation (Ctrl+Shift+C)"
                      selected: root.copied
                      iconText: root.copied ? "󰄬" : "󰆏"
                      fontSize: Style.font.bodySmall
                      fontFamily: root.chromeFont
                      horizontalPadding: Style.spacing.controlPaddingX
                      verticalPadding: Style.spacing.xxs
                      onClicked: root.copyResult()
                    }
                  }

                  Flickable {
                    id: resultFlick
                    anchors.top: resultHeader.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.topMargin: Style.spacing.controlGap
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    contentWidth: width
                    contentHeight: Math.max(height, resultArea.contentHeight + Style.space(4))

                    TextEdit {
                      id: resultArea
                      width: resultFlick.width
                      wrapMode: TextEdit.Wrap
                      selectByMouse: true
                      persistentSelection: true
                      textFormat: TextEdit.PlainText
                      color: root.foreground
                      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                      selectedTextColor: root.foreground
                      font.family: root.bodyFont
                      font.pixelSize: Style.font.body
                      onTextChanged: root.resultEdited()
                      onCursorRectangleChanged: {
                        var rect = cursorRectangle
                        if (rect.y < resultFlick.contentY) resultFlick.contentY = rect.y
                        else if (rect.y + rect.height > resultFlick.contentY + resultFlick.height)
                          resultFlick.contentY = rect.y + rect.height - resultFlick.height
                      }
                    }

                    Text {
                      x: 0
                      y: 0
                      enabled: false
                      visible: resultArea.text === ""
                      textFormat: Text.PlainText
                      text: root.busy ? "translating…" : "Translation appears here"
                      color: root.muted
                      opacity: 0.7
                      font.family: root.bodyFont
                      font.pixelSize: Style.font.body
                    }

                    MouseArea {
                      anchors.fill: parent
                      acceptedButtons: Qt.NoButton
                      onWheel: function(wheel) {
                        var limit = Math.max(0, resultFlick.contentHeight - resultFlick.height)
                        resultFlick.contentY = Math.max(0, Math.min(limit, resultFlick.contentY - wheel.angleDelta.y))
                      }
                    }

                    Rectangle {
                      readonly property real ratio: resultFlick.visibleArea.heightRatio
                      visible: resultFlick.contentHeight > resultFlick.height + 1
                      width: Style.space(3)
                      radius: width / 2
                      color: Util.alpha(root.foreground, 0.25)
                      x: resultFlick.width - width - Style.space(2)
                      y: resultFlick.visibleArea.yPosition * resultFlick.height
                      height: Math.max(Style.space(12), ratio * resultFlick.height)
                    }
                  }
                }
              }
            }

            // ------------------------------------------------ language picker
            Ui.BorderSurface {
              anchors.fill: parent
              visible: root.pickerOpen
              radius: root.cornerRadius
              color: Style.controlFill(true, false, root.foreground, root.accent)
              borderSpec: root.focusPaneBorder
              padding: root.panePadding

              Item {
                anchors.fill: parent
                anchors.topMargin: parent.contentTopInset
                anchors.rightMargin: parent.contentRightInset
                anchors.bottomMargin: parent.contentBottomInset
                anchors.leftMargin: parent.contentLeftInset

                Row {
                  id: pickerHeader
                  width: parent.width
                  height: root.chipHeight
                  spacing: Style.spacing.controlGap

                  Ui.Button {
                    text: "source " + root.sourceChip
                    tooltipText: "Set the source language (Ctrl+1)"
                    selected: root.pickerSide === "source"
                    bordered: true
                    fontSize: Style.font.bodySmall
                    fontFamily: root.chromeFont
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.xxs
                    onClicked: { root.pickerSide = "source"; root.rebuildPicker(root.pickerQuery) }
                  }

                  Ui.Button {
                    text: "target " + root.targetChip
                    tooltipText: "Set the target language (Ctrl+2)"
                    selected: root.pickerSide === "target"
                    bordered: true
                    fontSize: Style.font.bodySmall
                    fontFamily: root.chromeFont
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.xxs
                    onClicked: { root.pickerSide = "target"; root.rebuildPicker(root.pickerQuery) }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: root.pickerSide === "target"
                      ? "Pick the language to translate into"
                      : "Pick the language to translate from"
                    color: root.muted
                    font.family: root.chromeFont
                    font.pixelSize: Style.font.caption
                  }
                }

                Item {
                  id: pickerSearchFrame
                  anchors.top: pickerHeader.bottom
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.topMargin: Style.spacing.controlGap
                  height: Math.max(Style.space(28), Style.font.body + Style.spacing.controlPaddingY * 2)

                  TextInput {
                    id: pickerSearch
                    anchors.fill: parent
                    anchors.leftMargin: Style.spacing.controlPaddingX
                    anchors.rightMargin: Style.spacing.controlPaddingX
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.foreground
                    selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                    selectedTextColor: root.foreground
                    font.family: root.chromeFont
                    font.pixelSize: Style.font.body
                    onTextChanged: root.rebuildPicker(text)
                    onAccepted: root.applyPicker()

                    Keys.onUpPressed: root.movePicker(-1)
                    Keys.onDownPressed: root.movePicker(1)
                    Keys.onEscapePressed: root.closePicker()
                    Keys.onTabPressed: {
                      root.pickerSide = root.pickerSide === "source" ? "target" : "source"
                      root.rebuildPicker(root.pickerQuery)
                    }
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.controlPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    enabled: false
                    visible: pickerSearch.text === ""
                    textFormat: Text.PlainText
                    text: "Type to filter — code, English or native name"
                    color: root.muted
                    opacity: 0.7
                    font.family: root.chromeFont
                    font.pixelSize: Style.font.body
                  }

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: Math.max(1, Style.space(1))
                    color: Util.alpha(root.foreground, 0.25)
                  }
                }

                ListView {
                  id: pickerList
                  anchors.top: pickerSearchFrame.bottom
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: pickerFooter.top
                  anchors.topMargin: Style.spacing.sm
                  clip: true
                  model: root.pickerResults
                  boundsBehavior: Flickable.StopAtBounds
                  currentIndex: root.pickerIndex

                  delegate: Rectangle {
                    required property var modelData
                    required property int index

                    readonly property bool hasCursor: index === root.pickerIndex

                    width: pickerList.width
                    height: Math.max(Style.space(26), Style.font.body + Style.spacing.controlPaddingY * 2)
                    radius: root.cornerRadius
                    color: hasCursor ? root.selectedBackground : "transparent"

                    Row {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.spacing.controlPaddingX
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.spacing.md

                      Text {
                        textFormat: Text.PlainText
                        text: Languages.chip(modelData.code)
                        color: hasCursor ? root.selectedText : root.accent
                        font.family: root.chromeFont
                        font.pixelSize: Style.font.body
                        width: Style.space(46)
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: modelData.name
                        color: root.foreground
                        font.family: root.chromeFont
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: Languages.subtitle(modelData)
                        color: root.muted
                        font.family: root.chromeFont
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    Rectangle {
                      anchors.bottom: parent.bottom
                      width: parent.width
                      height: 1
                      visible: index < pickerList.count - 1
                      color: Util.alpha(root.foreground, 0.06)
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onContainsMouseChanged: if (containsMouse) root.pickerIndex = index
                      onClicked: {
                        root.pickerIndex = index
                        root.applyPicker()
                      }
                    }
                  }
                }

                Row {
                  id: pickerFooter
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Style.font.caption + Style.spacing.xs
                  spacing: Style.spacing.md

                  Text {
                    textFormat: Text.PlainText
                    text: "↑ ↓ choose · Enter apply · Tab source/target · Esc cancel"
                    color: root.muted
                    font.family: root.chromeFont
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // ------------------------------------------------------- help
            Ui.BorderSurface {
              anchors.fill: parent
              visible: root.showHelp
              radius: root.cornerRadius
              color: Style.controlFill(false, false, root.foreground, root.accent)
              borderSpec: root.normalPaneBorder
              padding: root.panePadding

              Column {
                anchors.fill: parent
                anchors.topMargin: parent.contentTopInset
                anchors.rightMargin: parent.contentRightInset
                anchors.bottomMargin: parent.contentBottomInset
                anchors.leftMargin: parent.contentLeftInset
                spacing: Style.spacing.xs

                Text {
                  textFormat: Text.PlainText
                  text: "Keyboard"
                  color: root.accent
                  font.family: root.chromeFont
                  font.pixelSize: Style.font.subtitle
                }

                Repeater {
                  model: root.helpRows

                  delegate: Row {
                    required property var modelData
                    width: parent.width
                    spacing: Style.spacing.md

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.keys
                      color: root.foreground
                      font.family: root.chromeFont
                      font.pixelSize: Style.font.body
                      width: Style.space(150)
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: modelData.action
                      color: root.muted
                      font.family: root.chromeFont
                      font.pixelSize: Style.font.body
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: "F1 hides this list · languages persist in " + root.statePath
                  color: root.muted
                  opacity: 0.7
                  font.family: root.chromeFont
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // -------------------------------------------------- deepl key
            Ui.BorderSurface {
              anchors.fill: parent
              visible: root.keyPanelOpen
              radius: root.cornerRadius
              color: Style.controlFill(true, false, root.foreground, root.accent)
              borderSpec: root.focusPaneBorder
              padding: root.panePadding

              Column {
                anchors.fill: parent
                anchors.topMargin: parent.contentTopInset
                anchors.rightMargin: parent.contentRightInset
                anchors.bottomMargin: parent.contentBottomInset
                anchors.leftMargin: parent.contentLeftInset
                spacing: Style.spacing.sm

                Text {
                  textFormat: Text.PlainText
                  text: "DeepL API key"
                  color: root.accent
                  font.family: root.chromeFont
                  font.pixelSize: Style.font.subtitle
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: root.deeplKey !== ""
                    ? "A key is saved. Paste a new one to replace it, or forget it."
                    : "Translate with DeepL on your own API key. The free plan covers 500 000 characters a month."
                  color: root.foreground
                  font.family: root.chromeFont
                  font.pixelSize: Style.font.body
                }

                Item {
                  width: parent.width
                  height: Math.max(Style.space(28), Style.font.body + Style.spacing.controlPaddingY * 2)

                  TextInput {
                    id: keyInput
                    anchors.fill: parent
                    anchors.leftMargin: Style.spacing.controlPaddingX
                    anchors.rightMargin: Style.spacing.controlPaddingX
                    verticalAlignment: TextInput.AlignVCenter
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    readOnly: root.keyChecking
                    color: root.foreground
                    selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                    selectedTextColor: root.foreground
                    font.family: root.chromeFont
                    font.pixelSize: Style.font.body
                    onAccepted: if (!root.keyChecking) root.submitKey(text)
                    Keys.onEscapePressed: root.closeKeyPanel()
                  }

                  Text {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.controlPaddingX
                    anchors.verticalCenter: parent.verticalCenter
                    enabled: false
                    visible: keyInput.text === ""
                    textFormat: Text.PlainText
                    text: "Paste the key here (a free-plan key ends in :fx)"
                    color: root.muted
                    opacity: 0.7
                    font.family: root.chromeFont
                    font.pixelSize: Style.font.body
                  }

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: Math.max(1, Style.space(1))
                    color: Util.alpha(root.foreground, 0.25)
                  }
                }

                Text {
                  width: parent.width
                  visible: root.keyStatus !== ""
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: root.keyStatus
                  color: root.keyChecking ? root.muted : root.urgent
                  font.family: root.chromeFont
                  font.pixelSize: Style.font.bodySmall
                }

                Row {
                  spacing: Style.spacing.sm

                  Ui.Button {
                    text: "check & save"
                    tooltipText: "Enter — check the key with DeepL, then save it"
                    bordered: true
                    fontSize: Style.font.bodySmall
                    fontFamily: root.chromeFont
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.xxs
                    onClicked: if (!root.keyChecking) root.submitKey(keyInput.text)
                  }

                  Ui.Button {
                    visible: root.deeplKey !== ""
                    text: "forget key"
                    tooltipText: "Delete the saved key and go back to Google"
                    bordered: true
                    fontSize: Style.font.bodySmall
                    fontFamily: root.chromeFont
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.xxs
                    onClicked: root.forgetKey()
                  }

                  Ui.Button {
                    text: "cancel"
                    tooltipText: "Esc"
                    fontSize: Style.font.bodySmall
                    fontFamily: root.chromeFont
                    horizontalPadding: Style.spacing.controlPaddingX
                    verticalPadding: Style.spacing.xxs
                    onClicked: root.closeKeyPanel()
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: "Get a key at deepl.com/your-account/keys (DeepL API Free). It is kept in "
                    + root.deeplKeyPath + " (mode 600) and sent only to DeepL, in a request header."
                  color: root.muted
                  opacity: 0.7
                  font.family: root.chromeFont
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ------------------------------------------------------- footer
          Row {
            width: parent.width
            height: root.footerHeight
            spacing: Style.spacing.sm

            Ui.Button {
              text: "⌃⏎ translate"
              tooltipText: "Ctrl+Enter — translate now"
              fontSize: Style.font.bodySmall
              fontFamily: root.chromeFont
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.xxs
              onClicked: { debounce.stop(); root.translateNow(true) }
            }

            Ui.Button {
              text: "⌃S swap"
              tooltipText: "Ctrl+S — swap languages and panes"
              fontSize: Style.font.bodySmall
              fontFamily: root.chromeFont
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.xxs
              onClicked: root.swap()
            }

            Ui.Button {
              text: "⌃L langs"
              tooltipText: "Ctrl+L — pick the source language (Ctrl+Shift+L for the target)"
              fontSize: Style.font.bodySmall
              fontFamily: root.chromeFont
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.xxs
              onClicked: root.openPicker("source")
            }

            Ui.Button {
              text: "⌃⇧C copy"
              tooltipText: "Ctrl+Shift+C — copy the translation"
              fontSize: Style.font.bodySmall
              fontFamily: root.chromeFont
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.xxs
              onClicked: root.copyResult()
            }

            Ui.Button {
              text: "⌃⇧V paste"
              tooltipText: "Ctrl+Shift+V — translate the clipboard"
              fontSize: Style.font.bodySmall
              fontFamily: root.chromeFont
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.xxs
              onClicked: root.pasteSource()
            }

            Ui.Button {
              text: "⌃P auto"
              tooltipText: "Ctrl+P — translate while typing"
              selected: root.autoTranslate
              fontSize: Style.font.bodySmall
              fontFamily: root.chromeFont
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.xxs
              onClicked: root.toggleAuto()
            }

            Ui.Button {
              text: root.copied ? "copied" : "⌃⇧X clear"
              tooltipText: "Ctrl+Shift+X — clear both panes"
              selected: root.copied
              fontSize: Style.font.bodySmall
              fontFamily: root.chromeFont
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.xxs
              onClicked: root.clearAll()
            }

            Ui.Button {
              text: "F1 keys"
              tooltipText: "F1 — show every shortcut"
              selected: root.showHelp
              fontSize: Style.font.bodySmall
              fontFamily: root.chromeFont
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.xxs
              onClicked: root.showHelp = !root.showHelp
            }
          }
        }
      }
    }
  }
}
