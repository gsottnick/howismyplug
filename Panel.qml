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

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string period: Model.PERIODS.indexOf(setting("period", "all")) >= 0 ? setting("period", "all") : "all"
  readonly property string countMode: ["total", "unique", "both"].indexOf(setting("countMode", "both")) >= 0 ? setting("countMode", "both") : "both"
  readonly property string barStat: Model.METRICS.indexOf(setting("barStat", "clones")) >= 0 ? setting("barStat", "clones") : "clones"
  readonly property bool animations: setting("animations", true) !== false
  readonly property bool milestones: setting("milestones", true) !== false
  readonly property string milestoneMetric: Model.METRICS.indexOf(setting("milestoneMetric", "clones")) >= 0 ? setting("milestoneMetric", "clones") : "clones"
  readonly property int milestoneStep: Math.max(1, Math.min(1000000, Number(setting("milestoneStep", 100)) || 100))

  readonly property string today: Model.dayKey(PlugStore.now)
  readonly property var allTime: Model.totalsFor(PlugStore.repos, "all", today)
  readonly property int barValue: Model.metricValue(allTime, barStat)
  readonly property string barText: PlugStore.repos.length === 0 ? "" : Model.compact(barValue)

  // A milestone crossed since the dropdown was last opened: the bar glows until then.
  readonly property int milestoneValue: Model.metricValue(allTime, milestoneMetric)
  readonly property bool milestonePending: milestones && PlugStore.stateLoaded
      && PlugStore.seenMilestone(milestoneMetric) >= 0
      && Model.checkMilestone(milestoneValue, milestoneStep, PlugStore.seenMilestone(milestoneMetric)).celebrate > 0
  readonly property bool disco: milestonePending && animations

  function applySettings() { PlugStore.applySettings(setting("pollEvery", "daily")) }
  onSettingsChanged: applySettings()
  Component.onCompleted: applySettings()

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

  onOpenedChanged: if (opened) { PlugStore.panelOpened(); view.reveal() }

  property real hue: 0
  NumberAnimation on hue { running: root.disco; from: 0; to: 1; duration: 1600; loops: Animation.Infinite }
  readonly property color discoColor: Qt.hsva(root.hue, 0.85, 1.0, 1.0)

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    tooltipText: {
      if (PlugStore.repos.length === 0) return "HowIsMyPlug?: add a repo to start tracking"
      var t = root.allTime
      var tip = "All time, " + PlugStore.repos.length + (PlugStore.repos.length === 1 ? " repo" : " repos")
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
        Text {
          anchors.centerIn: parent
          text: "\u{f06a5}"   // power plug
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          color: root.disco ? root.discoColor : (root.milestonePending ? Color.accent : root.barForeground)
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
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(view.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: view.editing
      onCloseRequested: root.close()
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
