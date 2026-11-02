import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// HowIsMyPlug? in the Omarchy bar: a plug glyph and one number you pick.
// The dropdown is PlugView.qml; PlugStore owns the data, once for every
// monitor's bar.
Panel {
  id: root
  moduleName: "io.github.gsottnick.howismyplug"
  ipcTarget: "io.github.gsottnick.howismyplug"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function pick(key, allowed, fallback) {
    var v = setting(key, fallback)
    return allowed.indexOf(v) >= 0 ? v : fallback
  }

  // Every setting, read from this widget's shell.json entry (written by the
  // settings page in the dropdown, or Omarchy's widget settings).
  readonly property string period: pick("period", Model.PERIODS, "all")
  readonly property string countMode: pick("countMode", ["total", "unique", "both"], "both")
  readonly property string barStat: pick("barStat", Model.METRICS, "clones")
  readonly property string barSource: {
    var v = String(setting("barSource", "all"))
    return v === "all" || Model.findRepo(PlugStore.repos, v) ? v : "all"
  }
  readonly property string panelSize: pick("panelSize", ["compact", "normal", "tall"], "normal")
  readonly property string accentRole: pick("accent", ["theme", "foreground", "urgent"], "theme")
  readonly property color accent: accentRole === "foreground" ? Color.foreground : (accentRole === "urgent" ? Color.urgent : Color.accent)
  // Off when the user turns them off here, or when Omarchy's own animations
  // are off (Omarchy 4.5+: `omarchy toggle animations`, read as Style.reduceMotion).
  readonly property bool animations: setting("animations", true) !== false && Style.reduceMotion !== true
  readonly property bool showCombined: setting("showCombined", true) !== false
  readonly property var combinedMilestone: ({
    on: setting("combinedMilestones", true) !== false,
    metric: pick("milestoneMetric", Model.METRICS, "clones"),
    step: Math.max(1, Math.min(1000000, Number(setting("milestoneStep", 100)) || 100))
  })
  readonly property string defaultCheckGithub: pick("defaultCheckGithub", Model.CHECKS, "daily")
  readonly property string defaultCheckListing: pick("defaultCheckListing", Model.CHECKS, "daily")

  // Panel sizes in Style.space units. The height is fixed: long repo lists scroll.
  readonly property var metrics: panelSize === "compact" ? { width: 360, height: 520 }
    : (panelSize === "tall" ? { width: 440, height: 820 } : { width: 400, height: 640 })

  readonly property string today: Model.dayKey(PlugStore.now)
  readonly property int barValue: Model.barValue(PlugStore.repos, barSource, barStat, today)
  readonly property string barText: PlugStore.repos.length === 0 ? "" : Model.compact(barValue)

  // A milestone crossed since the dropdown was last opened: the bar glows until then.
  readonly property bool milestonePending: PlugStore.stateLoaded
      && Model.milestoneCheck(PlugStore.repos, combinedMilestone, PlugStore.state.seen, today).celebrations.length > 0
  readonly property bool disco: milestonePending && animations

  // Read straight from the settings: this runs on settingsChanged, before
  // the properties derived from them have caught up.
  function applySettings() {
    PlugStore.applySettings(pick("defaultCheckGithub", Model.CHECKS, "daily"), pick("defaultCheckListing", Model.CHECKS, "daily"))
  }
  onSettingsChanged: applySettings()

  // Omarchy's own pattern (its clock panel): apply locally so the panel
  // updates on the click, then write this widget's shell.json entry.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  onOpenedChanged: if (opened) { PlugStore.panelOpened(); view.reveal() } else view.reset()

  property real hue: 0
  NumberAnimation on hue { running: root.disco; from: 0; to: 1; duration: 1600; loops: Animation.Infinite }
  readonly property color discoColor: Qt.hsva(root.hue, 0.85, 1.0, 1.0)

  // The number beside the plug. Omarchy 4.5+ draws a label beside a bar icon
  // itself (BarIconButton.labelText, like the battery percentage); 4.0.x
  // doesn't, so there it is drawn next to the plug inside the icon. Which one
  // is chosen by asking the installed Omarchy, so an Omarchy update switches
  // over on the next shell start with nothing to change here.
  readonly property bool nativeLabel: button.labelText !== undefined

  FontMetrics {
    id: labelMetrics
    font.family: root.fontFamily
    font.pixelSize: root.nativeLabel ? Style.bar.iconFont : Style.font.body
  }
  readonly property real labelWidth: barText === "" ? 0 : labelMetrics.advanceWidth(barText)
  // 4.0.x: the icon is the plug plus the number.
  readonly property real drawnWidth: Style.bar.iconFont + (labelWidth > 0 ? Style.space(5) + labelWidth : 0)

  Component.onCompleted: {
    applySettings()
    if (nativeLabel) {
      button.labelText = Qt.binding(function() { return root.barText })
      button.slotSize = Qt.binding(function() {
        return Style.bar.iconSlot + (root.labelWidth > 0 ? root.labelWidth + Style.space(4) : 0)
      })
    } else {
      button.opticalSize = Qt.binding(function() { return Math.max(Style.bar.iconCanvas, root.drawnWidth) })
      button.slotSize = Qt.binding(function() {
        return root.labelWidth > 0 ? root.drawnWidth + Style.space(10) : Style.bar.iconSlot
      })
    }
  }

  BarIconButton {
    id: button
    objectName: "barButton"
    anchors.fill: parent
    bar: root.bar
    tooltipText: {
      if (PlugStore.repos.length === 0) return "HowIsMyPlug?: add a repo to start tracking"
      var one = root.barSource === "all" ? null : Model.findRepo(PlugStore.repos, root.barSource)
      var t = Model.totalsFor(one ? [one] : PlugStore.repos, "all", root.today)
      var tip = (one ? one.repo : "All repos") + ", all time"
          + "\nClones " + Model.countText(t.clones.count, t.clones.uniques, "both")
          + "\nRepo views " + Model.countText(t.views.count, t.views.uniques, "both")
          + "\nListing views " + Model.grouped(t.market.views) + " · copies " + Model.grouped(t.market.copies) + " · hearts " + Model.grouped(t.market.hearts)
      if (root.milestonePending) tip += "\nNew milestone! Click to see it."
      return tip
    }
    iconComponent: Component {
      Item {
        Rectangle {
          anchors.centerIn: parent
          width: Style.bar.iconFont + Style.space(10)
          height: width
          radius: width / 2
          color: root.discoColor
          visible: root.disco
          SequentialAnimation on opacity {
            running: root.disco
            loops: Animation.Infinite
            NumberAnimation { from: 0.10; to: 0.35; duration: 500; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.35; to: 0.10; duration: 500; easing.type: Easing.InOutSine }
          }
        }
        Row {
          anchors.centerIn: parent
          spacing: Style.space(5)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "\u{f06a5}"   // power plug
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
            color: root.disco ? root.discoColor : (root.milestonePending ? root.accent : root.barForeground)
          }
          Text {
            objectName: "barNumber"
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.nativeLabel && root.barText !== ""
            text: root.barText
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            renderType: Text.NativeRendering
            color: root.disco ? Qt.hsva((root.hue + 0.5) % 1, 0.85, 1.0, 1.0) : root.barForeground
          }
        }
      }
    }
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    objectName: "keyboardPanel"
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.metrics.width))
    contentHeight: panel.fittedContentHeight(Style.space(root.metrics.height), Style.space(root.metrics.height))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: view.editing
      onCloseRequested: view.back()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    PlugView {
      id: view
      objectName: "plugView"
      anchors.fill: parent
      panel: root
      active: root.opened
    }
  }
}
