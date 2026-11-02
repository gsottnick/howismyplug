import QtQuick
import qs.Commons

// The slice of Omarchy's bar API that a bar widget and its popup panel touch.
// Real behaviour where the panel depends on it (popout ownership); inert
// acknowledgement everywhere else.
QtObject {
  id: bar

  property string position: "top"
  property int barSize: Style.bar.sizeHorizontal
  property bool vertical: false
  property color foreground: Color.foreground
  property color background: Color.background
  property color barForeground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property bool foregroundAnimationEnabled: false

  property var activePopout: null

  // What the widget saved through the shell, so tests can check what lands in
  // shell.json without a real shell.
  property var writes: []
  property QtObject shell: QtObject {
    function updateEntryInline(moduleName, entry) {
      bar.writes = bar.writes.concat([entry])
      return true
    }
  }
  property var clickTargets: []

  function requestPopout(key) { activePopout = key }
  function releasePopout(key) { if (activePopout === key) activePopout = null }
  function targetBelongsToWindow(target, window) { return true }
  function switchPanelFrom(panel, direction) { return false }
  function showTooltip(owner, text) {}
  function hideTooltip(owner) {}
  function moduleWidgets(moduleName) { return [] }
}
