import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui as Ui
import "Languages.js" as Languages

// Keyboard-first translation overlay for omarchy-shell.
//
// SUPER + SHIFT + K summons it. Two panes (source, translation), a language
// chip per pane, and a filterable language picker. Everything the mouse can do
// has a key: Ctrl+Enter translate, Ctrl+S swap, Ctrl+L pick the source
// language, Ctrl+Shift+L the target, Ctrl+Shift+C copy the result,
// Ctrl+Shift+V translate the clipboard, Ctrl+Shift+X clear, Ctrl+P toggle
// auto-translate, F1 the shortcut list, Esc close.
//
// The overlay lives inside the long-lived omarchy-shell process and keeps its
// panes, chosen languages, and in-flight request across summons (manifest
// keepLoaded). All network work lives in bin/translate-fetch: the QML hands
// the script the text as argv and reads one JSON object back, so the view
// never speaks HTTP and a hung request can be killed without touching the UI.
Item {
  id: root

  // Injected by the shell's panel loader.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "io.github.baltavay.translate"
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")
  readonly property string fetchScript: pluginDir + "bin/translate-fetch"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy"
  readonly property string statePath: stateDir + "/translate.json"

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

  property bool pickerOpen: false
  property string pickerSide: "source"
  property string pickerQuery: ""
  property int pickerIndex: 0
  property var pickerResults: []

  property int requestSeq: 0
  property int pendingSeq: -1
  property bool queuedTranslate: false
  property bool outputHandled: false
  property real startedAt: 0
  property string stderrText: ""
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
    Qt.callLater(function() { root.focusSource() })
  }

  function close() {
    root.opened = false
    root.pickerOpen = false
    root.showHelp = false
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
    Quickshell.execDetached(["wl-copy", "--type", "text/plain", text])
    root.copied = true
    copyFlash.restart()
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

  function startFetch(text) {
    root.requestSeq += 1
    root.pendingSeq = root.requestSeq
    root.outputHandled = false
    root.stderrText = ""
    root.startedAt = Date.now()
    root.busy = true
    root.status = "translating…"
    root.errorText = ""
    fetchProc.command = [root.fetchScript, root.sourceLang, root.targetLang, text]
    fetchProc.running = true
  }

  function cancelFetch() {
    if (!fetchProc.running) return
    root.pendingSeq = -1
    fetchProc.running = false
  }

  function handleFetchOutput(raw) {
    if (root.outputHandled) return
    if (root.pendingSeq === -1) return
    root.outputHandled = true
    root.pendingSeq = -1
    root.busy = false

    var reply = null
    try { reply = JSON.parse(String(raw || "")) } catch (e) { reply = null }
    if (!reply || typeof reply !== "object") {
      var detail = String(root.stderrText || "").trim()
      root.fail(detail !== "" ? detail : "translate-fetch returned nothing usable")
      return
    }
    if (reply.ok !== true) {
      root.fail(String(reply.error || "translation failed"))
      return
    }

    root.translatedSource = root.sourceText
    root.setResultText(String(reply.text || ""))
    root.engine = String(reply.engine || "")
    if (reply.detected) root.detectedLang = String(reply.detected)
    root.errorText = ""
    var parts = []
    if (root.engine && root.engine !== "none") parts.push(root.engine)
    parts.push((Date.now() - root.startedAt) + " ms")
    parts.push(root.sourceText.length + " chars")
    if (root.sourceLang === "auto" && root.detectedLang)
      parts.push("detected " + root.detectedLang)
    root.status = parts.join(" · ")
  }

  function fail(message) {
    root.busy = false
    root.status = ""
    root.errorText = String(message)
  }

  // -------------------------------------------------------- language picker

  function openPicker(side) {
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

    if (event.key === Qt.Key_F1) { root.showHelp = !root.showHelp; return true }
    if (event.key === Qt.Key_Escape) {
      if (root.pickerOpen) root.closePicker()
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
  }

  function writeState() {
    stateFile.setText(JSON.stringify({
      version: 1,
      source: root.sourceLang,
      target: root.targetLang,
      auto: root.autoTranslate
    }, null, 2) + "\n")
  }

  onSourceLangChanged: stateSave.restart()
  onTargetLangChanged: stateSave.restart()
  onAutoTranslateChanged: stateSave.restart()

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

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleFetchOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.stderrText = text
    }
    onExited: function(exitCode, exitStatus) {
      root.busy = false
      if (root.pendingSeq !== -1 && !root.outputHandled) {
        var detail = String(root.stderrText || "").replace(/\s+$/, "")
        root.pendingSeq = -1
        root.fail("translate-fetch exited with code " + exitCode + (detail ? ": " + detail : ""))
      }
      root.outputHandled = false
      if (root.queuedTranslate) {
        root.queuedTranslate = false
        root.translateNow(true)
      }
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

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, parent.width * 0.6)
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.errorText !== "" ? root.errorText : root.status
              color: root.errorText !== "" ? root.urgent : (root.copied ? root.accent : root.muted)
              font.family: root.chromeFont
              font.pixelSize: Style.font.bodySmall
            }
          }

          // ---------------------------------------------- panes / picker
          Item {
            width: parent.width
            height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

            Row {
              anchors.fill: parent
              spacing: root.paneGap
              visible: !root.pickerOpen && !root.showHelp

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
