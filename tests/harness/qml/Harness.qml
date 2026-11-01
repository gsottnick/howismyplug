import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
// The plugin folder itself, for the PlugStore singleton the panel shares.
import "../../.." as Plugin

// Hosts the HowIsMyPlug? bar widget in a stand-in Omarchy bar so the real
// plugin entry point, the real Omarchy Ui components and the fake GitHub and
// marketplace servers all run together outside a Wayland session.
QtObject {
  id: harness

  property url pluginUrl
  property var pluginSettings: ({})

  readonly property var plugin: pluginLoader.item
  readonly property var store: Plugin.PlugStore
  readonly property var barModel: fakeBar
  readonly property bool ready: pluginLoader.status === Loader.Ready

  property FakeBar fakeBar: FakeBar {}

  function openPanel() { if (plugin) plugin.open() }
  function closePanel() { if (plugin) plugin.close() }

  property var barWindow: PanelWindow {
    id: barWindow
    color: Color.background
    visible: true
    height: Style.bar.sizeHorizontal

    anchors {
      top: true
      left: true
      right: true
    }

    Row {
      id: widgetRow
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "  1  2  3"
        color: Qt.darker(Color.foreground, 1.6)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      Loader {
        id: pluginLoader
        anchors.verticalCenter: parent.verticalCenter
        source: harness.pluginUrl
        onLoaded: {
          item.bar = harness.fakeBar
          item.settings = harness.pluginSettings
        }
      }
    }
  }
}
