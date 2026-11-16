import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// GoPro webcam bar widget + popup panel. All camera work goes through the
// `bin/gopro-webcam` helper shipped with this plugin; this file only polls
// `status --json` and runs actions.
Panel {
  id: root
  moduleName: "io.github.ingermanr.gopro"
  ipcTarget: "io.github.ingermanr.gopro"

  // Resolved relative to this file, so the plugin works wherever it is installed.
  readonly property string cli: String(Qt.resolvedUrl("bin/gopro-webcam")).replace(/^file:\/\//, "")
  readonly property string downloadDir: Quickshell.env("HOME") + "/Videos"

  readonly property string glyphCamera: String.fromCodePoint(0xF0567)    // nf-md-video
  readonly property string glyphCameraOff: String.fromCodePoint(0xF0568) // nf-md-video_off

  readonly property var lensOptions: [
    { value: "wide", label: "Wide" },
    { value: "narrow", label: "Narrow" },
    { value: "superview", label: "SuperView" },
    { value: "linear", label: "Linear" }
  ]
  readonly property var resOptions: [
    { value: "1080", label: "1080p" },
    { value: "720", label: "720p" },
    { value: "480", label: "480p" }
  ]

  // ---------- Status ----------
  property var status: ({ connected: false })
  property bool statusLoaded: false
  property bool refreshQueued: false

  readonly property bool connected: status.connected === true
  readonly property bool webcamOn: connected && (status.webcam === "streaming" || status.process === true)
  readonly property bool recording: connected && status.recording === true
  // The camera refuses to record or take photos on USB power alone.
  readonly property bool hasBattery: connected && status.battery !== null && status.battery !== undefined
  readonly property string lens: connected && status.lens ? String(status.lens) : ""
  readonly property string res: connected && status.res ? String(status.res) : ""

  // ---------- Actions ----------
  property string busyAction: ""
  property string errorText: ""
  readonly property bool busy: busyAction !== ""

  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 15)), 10)
    if (!isFinite(n)) n = 15
    return Math.max(5, Math.min(3600, n))
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string stateLabel: {
    if (busyAction === "start") return "Starting…"
    if (busyAction === "stop") return "Stopping…"
    if (!statusLoaded) return "Checking…"
    if (!connected) return "Not connected"
    if (webcamOn) return "Streaming"
    if (recording) return "Recording"
    return "Off"
  }

  readonly property string detailLabel: {
    if (!connected) return ""
    var parts = []
    parts.push(status.battery === null || status.battery === undefined ? "USB power" : "Battery " + status.battery + "%")
    if (status.sdFreeGb !== null && status.sdFreeGb !== undefined) parts.push("SD " + status.sdFreeGb + " GB free")
    return parts.join(" · ")
  }

  readonly property string tooltip: {
    if (!statusLoaded) return "GoPro"
    if (!connected) return "GoPro not connected"
    var text = "GoPro · " + stateLabel
    if (webcamOn) {
      var bits = []
      if (res) bits.push(res + "p")
      if (lens) bits.push(labelFor(lensOptions, lens))
      if (bits.length > 0) text += " (" + bits.join(", ") + ")"
    }
    return text
  }

  function labelFor(options, value) {
    for (var i = 0; i < options.length; i++) if (options[i].value === value) return options[i].label
    return value
  }

  function refresh() {
    if (statusProc.running) {
      refreshQueued = true
      return
    }
    statusProc.running = true
  }

  function applyStatus(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw).trim()) } catch (e) { parsed = null }
    status = parsed && typeof parsed === "object" ? parsed : { connected: false }
    statusLoaded = true
  }

  function run(action, args) {
    if (busy) return
    errorText = ""
    busyAction = action
    actionProc.command = [root.cli].concat(args)
    actionProc.running = true
  }

  function startWebcam() {
    run("start", ["start", "-d", res || "1080", lens || "wide"])
  }

  function stopWebcam() { run("stop", ["stop"]) }

  function toggleWebcam() {
    if (!connected || busy) return
    if (webcamOn) stopWebcam()
    else startWebcam()
  }

  function setLens(value) {
    if (!webcamOn || value === lens) return
    run("lens", ["lens", value])
  }

  function setRes(value) {
    if (!webcamOn || value === res) return
    run("res", ["res", value])
  }

  function toggleRecording() {
    if (webcamOn || !hasBattery) return
    if (recording) run("record-stop", ["record-stop"])
    else run("record", ["record"])
  }

  function takePhoto() {
    if (webcamOn || !hasBattery) return
    run("photo", ["photo"])
  }

  function downloadLatest() {
    if (webcamOn) return
    run("download", ["download", "latest", root.downloadDir])
  }

  function finishAction(exitCode) {
    if (exitCode !== 0) {
      var lines = String(actionErr.text || "").trim().split("\n")
      var last = lines.length > 0 ? lines[lines.length - 1].trim() : ""
      errorText = (last !== "" ? last : busyAction + " failed (exit " + exitCode + ")")
    }
    busyAction = ""
    refresh()
  }

  onOpenedChanged: if (opened) refresh()
  Component.onCompleted: refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onExited: {
      if (root.refreshQueued) {
        root.refreshQueued = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    // Defer one tick so the stderr collector has flushed its final text.
    onExited: function(exitCode, exitStatus) {
      Qt.callLater(function() { root.finishAction(exitCode) })
    }
  }

  // Poll faster while the panel is open; never overlaps (refresh() queues).
  Timer {
    interval: root.opened ? 5000 : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: if (!root.busy) root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.statusLoaded && !root.connected ? root.glyphCameraOff : root.glyphCamera
    opacity: !root.connected ? 0.25 : (root.webcamOn ? 1 : 0.5)
    tooltipText: root.tooltip
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleWebcam()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.connected ? root.glyphCamera : root.glyphCameraOff
            color: root.webcamOn ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "GoPro HERO12"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.stateLabel.toUpperCase()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              visible: text !== ""
              textFormat: Text.PlainText
              text: root.detailLabel
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Not connected ----------
        Text {
          visible: root.statusLoaded && !root.connected
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: "Connect the GoPro via USB (GoPro Connect mode)."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Busy / error line ----------
        Text {
          visible: root.busy || root.errorText !== ""
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
          text: root.busy ? "Working…" : root.errorText
          color: root.busy ? root.dim : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---------- Controls (connected only) ----------
        Column {
          visible: root.connected
          width: parent.width
          spacing: Style.space(14)

          PanelSeparator { foreground: root.foreground }

          Section {
            title: "WEBCAM"

            Button {
              width: parent.width
              enabled: !root.busy
              opacity: enabled ? 1 : 0.5
              iconText: root.webcamOn ? root.glyphCameraOff : root.glyphCamera
              iconSize: Style.font.title
              text: root.busyAction === "start" ? "Starting…"
                : (root.busyAction === "stop" ? "Stopping…"
                : (root.webcamOn ? "Stop webcam" : "Start webcam"))
              fontSize: Style.font.bodySmall
              foreground: root.foreground
              fontFamily: root.fontFamily
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.webcamOn
              onClicked: root.toggleWebcam()
            }
          }

          Section {
            title: "LENS"
            ChoiceRow {
              options: root.lensOptions
              current: root.lens
              enabled: root.webcamOn && !root.busy
              onChosen: function(value) { root.setLens(value) }
            }
          }

          Section {
            title: "RESOLUTION"
            ChoiceRow {
              options: root.resOptions
              current: root.res
              enabled: root.webcamOn && !root.busy
              onChosen: function(value) { root.setRes(value) }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Section {
            title: root.webcamOn ? "CAMERA · STOP WEBCAM FIRST"
              : (root.hasBattery ? "CAMERA" : "CAMERA · RECORD AND PHOTO NEED BATTERY")

            Row {
              id: cameraRow
              width: parent.width
              spacing: Style.space(6)
              enabled: !root.busy
              readonly property real cellWidth: (width - spacing * 2) / 3

              ActionButton {
                width: cameraRow.cellWidth
                iconText: String.fromCodePoint(root.recording ? 0xF04DB : 0xF044A) // stop / record
                text: root.recording ? "Stop rec" : "Record"
                active: root.recording
                enabled: !root.webcamOn && root.hasBattery
                tooltipText: root.hasBattery
                  ? "Grabar video (puede no estar soportado por el firmware de la cámara)"
                  : "Insert a battery to record"
                onClicked: root.toggleRecording()
              }
              ActionButton {
                width: cameraRow.cellWidth
                iconText: String.fromCodePoint(0xF0100) // nf-md-camera
                text: "Photo"
                enabled: !root.webcamOn && root.hasBattery
                tooltipText: root.hasBattery
                  ? "Tomar foto (puede no estar soportado por el firmware de la cámara)"
                  : "Insert a battery to take photos"
                onClicked: root.takePhoto()
              }
              ActionButton {
                width: cameraRow.cellWidth
                iconText: String.fromCodePoint(0xF01DA) // nf-md-download
                text: "Download"
                enabled: !root.webcamOn
                tooltipText: "Copy the newest photo/video from the SD card to ~/Videos"
                onClicked: root.downloadLatest()
              }
            }
          }
        }
      }
    }
  }

  component Section: Column {
    property string title: ""
    width: parent ? parent.width : 0
    spacing: Style.space(10)

    PanelSectionHeader {
      text: parent.title
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  component ActionButton: Button {
    iconSize: Style.font.title
    fontSize: Style.font.bodySmall
    foreground: root.foreground
    fontFamily: root.fontFamily
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
    opacity: enabled && (parent ? parent.enabled : true) ? 1 : 0.4
  }

  // Equal-width row of mutually exclusive choices, highlighting `current`.
  component ChoiceRow: Row {
    id: choiceRow
    property var options: []
    property string current: ""
    signal chosen(string value)

    width: parent ? parent.width : 0
    spacing: Style.space(6)
    opacity: enabled ? 1 : 0.4
    readonly property real cellWidth: options.length > 0 ? (width - spacing * (options.length - 1)) / options.length : 0

    Repeater {
      model: choiceRow.options
      Button {
        required property var modelData
        width: choiceRow.cellWidth
        text: modelData.label
        fontSize: Style.font.bodySmall
        foreground: root.foreground
        fontFamily: root.fontFamily
        horizontalPadding: Style.space(4)
        verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
        bordered: true
        active: choiceRow.current === modelData.value
        onClicked: choiceRow.chosen(modelData.value)
      }
    }
  }
}
