import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The HowIsMyPlug? dropdown: totals for the chosen period, the tracked repos,
// GitHub sign-in, and the milestone card. `panel` is Panel.qml (settings);
// PlugStore holds the data.
Item {
  id: root

  property var panel: null
  property bool active: false
  readonly property bool editing: repoField.activeFocus || tokenField.activeFocus
  implicitHeight: col.implicitHeight + Style.space(24)

  readonly property string ff: panel ? panel.fontFamily : Style.font.family
  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.58)
  readonly property color accent: Color.accent
  readonly property bool anim: panel ? panel.animations : true
  readonly property string period: panel ? panel.period : "all"
  readonly property string mode: panel ? panel.countMode : "both"
  readonly property string today: Model.dayKey(PlugStore.now)
  readonly property var totals: Model.totalsFor(PlugStore.repos, period, today)
  readonly property bool hasRepos: PlugStore.repos.length > 0
  // Unique numbers summed from daily uniques are labelled as such.
  readonly property bool approxUnique: mode !== "total" && period !== "14d"

  property string repoError: ""
  property string tokenError: ""
  property bool tokenMode: false
  property bool codeCopied: false
  Timer { id: copiedTimer; interval: 2000; onTriggered: root.codeCopied = false }

  function ago(ms) {
    if (!(ms > 0)) return "never"
    var s = (PlugStore.now - ms) / 1000
    if (s < 90) return "just now"
    if (s < 5400) return Math.round(s / 60) + " min ago"
    if (s < 172800) return Math.round(s / 3600) + " h ago"
    return Math.round(s / 86400) + " days ago"
  }

  function trafficWords(series, noun) {
    var t = Model.trafficFor(series, root.period, root.today)
    return Model.countWords(t.count, t.uniques, root.mode, noun)
  }

  // Two lines per repo: GitHub traffic, then the marketplace listing.
  function repoLine(r) {
    var github
    if (r.access === "denied" || r.access === "missing") github = "No access to traffic yet"
    else if (!PlugStore.signedIn) github = "Sign in for clones and views"
    else if (r.clones) github = trafficWords(r.clones, "clones") + "  ·  " + trafficWords(r.views, "views")
    else github = "Waiting for GitHub"
    var listing
    if (r.market) {
      var m = Model.marketFor(r.market, root.period, root.today)
      listing = "Listing  " + Model.grouped(m.views) + " views  ·  " + Model.grouped(m.copies) + " copies  ·  " + Model.grouped(m.hearts) + " \u2665"
    } else if (r.idChecked && !r.pluginId) {
      listing = "Not a plugin repo"
    } else if (r.pluginId) {
      listing = "Not on the marketplace yet"
    } else {
      listing = "Looking for a plugin listing…"
    }
    return github + "\n" + listing
  }

  // Tile numbers: the big one follows the count mode, "N unique" goes under it.
  function big(t) {
    if (!PlugStore.signedIn && t.count === 0) return "—"
    return Model.grouped(root.mode === "unique" ? t.uniques : t.count)
  }
  function sub(t) {
    if (!PlugStore.signedIn && t.count === 0) return "sign in to track"
    return root.mode === "both" ? Model.grouped(t.uniques) + " unique" : (root.mode === "unique" ? "unique" : "")
  }

  function addRepo() {
    root.repoError = PlugStore.addRepo(repoField.text)
    if (!root.repoError) repoField.text = ""
  }

  function saveToken() {
    root.tokenError = PlugStore.submitToken(tokenField.text)
    tokenField.text = ""
    if (!root.tokenError) root.tokenMode = false
  }

  // ── reveal + milestones ─────────────────────────────────────────────
  // Called each time the dropdown opens.
  function reveal() {
    if (root.anim) for (var i = 0; i < tiles.count; i++) tiles.itemAt(i).play()
    Qt.callLater(checkMilestone)
  }

  property int shownMilestone: 0
  property string shownMetric: ""
  property real celebrate: 0
  property real cardOpacity: 0
  property real cardScale: 1
  property real cardRule: 0

  function checkMilestone() {
    if (!root.active || !panel || !panel.milestones || !PlugStore.stateLoaded) return
    var metric = panel.milestoneMetric
    var r = Model.checkMilestone(panel.milestoneValue, panel.milestoneStep, PlugStore.seenMilestone(metric))
    if (r.seen !== PlugStore.seenMilestone(metric)) PlugStore.setSeenMilestone(metric, r.seen)
    if (r.celebrate > 0) celebrateMilestone(r.celebrate, metric)
  }

  function celebrateMilestone(value, metric) {
    root.shownMilestone = value
    root.shownMetric = metric
    cardNum.target = Model.grouped(value)
    if (root.anim) confetti.burst()
    celebrateAnim.restart()
  }

  // Numbers that arrive (and cross a milestone) while the dropdown is open count too.
  onTotalsChanged: if (active) Qt.callLater(checkMilestone)

  onActiveChanged: if (!active) {
    celebrateAnim.stop()
    root.celebrate = 0; root.cardOpacity = 0
    confetti.reset()
  }

  // ── everything but the milestone card; blurred under it ─────────────
  Item {
    id: scene
    anchors.fill: parent
    layer.enabled: root.celebrate > 0
    layer.effect: MultiEffect {
      autoPaddingEnabled: false
      blurEnabled: true
      blur: root.celebrate
      blurMax: 40
      brightness: -0.18 * root.celebrate
    }

    TokenRain {
      anchors.fill: parent
      opacity: 0.16
      visible: root.anim
      running: root.active && root.anim
      glyphColor: root.accent
      glyphs: "0123456789+↓↑⇣⇡·*#"
    }

    Flickable {
      id: flick
      objectName: "pageView"
      anchors.fill: parent
      anchors.margins: Style.space(12)
      contentHeight: col.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: col
        width: flick.width
        spacing: Style.space(10)

        // ── header ──
        Item {
          width: parent.width
          height: Math.max(title.implicitHeight, refresh.height)
          Text {
            id: title
            anchors.verticalCenter: parent.verticalCenter
            text: "HowIsMyPlug?"
            color: root.fg
            font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
          }
          PanelActionButton {
            id: refresh
            objectName: "refreshButton"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\u{f0450}"
            tooltipText: PlugStore.polling ? "Checking…" : "Check now"
            foreground: root.fg
            fontFamily: root.ff
            enabled: !PlugStore.polling
            onClicked: PlugStore.pollNow()
          }
        }

        ButtonGroup {
          id: periodGroup
          objectName: "periodGroup"
          focusable: false
          foreground: root.fg
          accent: root.accent
          fontFamily: root.ff
          fontSize: Style.font.bodySmall
          options: [{ value: "7d", label: "7 days" }, { value: "14d", label: "14 days" }, { value: "30d", label: "30 days" }, { value: "all", label: "All time" }]
          value: root.period
          onChanged: function(value) { if (root.panel) root.panel.persistSettings({ period: value }) }
        }

        // ── totals ──
        Grid {
          visible: root.hasRepos
          width: parent.width
          columns: 2
          columnSpacing: Style.space(10)
          rowSpacing: Style.space(10)

          Repeater {
            id: tiles
            model: [
              { label: "CLONES", value: root.big(root.totals.clones), sub: root.sub(root.totals.clones) },
              { label: "REPO VIEWS", value: root.big(root.totals.views), sub: root.sub(root.totals.views) },
              { label: "LISTING VIEWS", value: Model.grouped(root.totals.market.views), sub: "" },
              { label: "COPIES · HEARTS", value: Model.grouped(root.totals.market.copies) + " · " + Model.grouped(root.totals.market.hearts), sub: "" }
            ]
            delegate: Column {
              required property var modelData
              width: (col.width - Style.space(10)) / 2
              spacing: Style.space(2)
              function play() { num.play() }
              Text {
                text: modelData.label
                color: root.dim
                font.family: root.ff; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.5
              }
              DecryptText {
                id: num
                width: parent.width
                elide: Text.ElideRight
                target: modelData.value
                duration: root.anim ? 900 : 1
                settledColor: root.fg; scrambleColor: root.accent
                font.family: root.ff; font.pixelSize: Style.font.title + 4; font.bold: true
              }
              Text {
                visible: modelData.sub !== ""
                text: modelData.sub
                color: root.dim
                font.family: root.ff; font.pixelSize: Style.font.caption
              }
            }
          }
        }

        Text {
          visible: root.hasRepos && root.mode !== "total" && PlugStore.signedIn
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.approxUnique
            ? "Unique adds up each day's unique visitors; GitHub doesn't keep more than that."
            : "Unique is GitHub's exact 14-day count."
          color: root.dim
          font.family: root.ff; font.pixelSize: Style.font.caption
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ── tracked repos ──
        PanelSectionHeader { text: "TRACKING"; foreground: root.fg; fontFamily: root.ff }

        Text {
          visible: !root.hasRepos
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Add a repo you own. Plugin repos also show their marketplace listing."
          color: root.dim
          font.family: root.ff; font.pixelSize: Style.font.bodySmall
        }

        Repeater {
          model: PlugStore.repos
          delegate: Column {
            required property var modelData
            width: col.width
            spacing: Style.space(3)

            Item {
              width: parent.width
              height: Math.max(name.implicitHeight, remove.height)
              Text {
                id: name
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - remove.width - access.width - Style.space(12)
                text: modelData.repo
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.fg
                font.family: root.ff; font.pixelSize: Style.font.body; font.bold: true
              }
              Button {
                id: access
                objectName: "giveAccess-" + modelData.repo
                anchors.right: remove.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                visible: PlugStore.signedIn && (modelData.access === "denied" || modelData.access === "missing")
                width: visible ? implicitWidth : 0
                text: "Give access"
                bordered: true
                foreground: root.fg
                fontFamily: root.ff
                fontSize: Style.font.bodySmall
                onClicked: PlugStore.openUrl(PlugStore.installUrl)
              }
              PanelActionButton {
                id: remove
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\u{f0156}"
                tooltipText: "Stop tracking (keeps nothing)"
                foreground: root.dim
                fontFamily: root.ff
                onClicked: PlugStore.removeRepo(modelData.repo)
              }
            }
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.repoLine(modelData)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.ff; font.pixelSize: Style.font.bodySmall
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          TextField {
            id: repoField
            objectName: "repoField"
            width: parent.width - trackButton.width - Style.space(6)
            foreground: root.fg
            placeholderText: "e.g. yourname/my-omarchy-plugin"
            onAccepted: root.addRepo()
          }
          Button {
            id: trackButton
            text: "Track"
            bordered: true
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.addRepo()
          }
        }
        Text {
          visible: root.repoError !== ""
          text: root.repoError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.ff; font.pixelSize: Style.font.bodySmall
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ── GitHub account ──
        PanelSectionHeader { text: "GITHUB"; foreground: root.fg; fontFamily: root.ff }

        Column {
          visible: PlugStore.signedIn
          width: parent.width
          spacing: Style.space(6)
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: PlugStore.authMethod === "token" ? "Using your token, kept in the system keyring." : "Signed in with the HowIsMyPlug GitHub app (read-only traffic)."
            color: root.fg
            font.family: root.ff; font.pixelSize: Style.font.bodySmall
          }
          Row {
            spacing: Style.space(6)
            Button {
              visible: PlugStore.authMethod !== "token"
              text: "Choose repos"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              fontSize: Style.font.bodySmall
              onClicked: PlugStore.openUrl(PlugStore.installUrl)
            }
            Button {
              objectName: "signOutButton"
              text: "Sign out"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              fontSize: Style.font.bodySmall
              onClicked: PlugStore.signOut()
            }
          }
        }

        Column {
          visible: !PlugStore.signedIn && PlugStore.signingIn && PlugStore.userCode !== ""
          width: parent.width
          spacing: Style.space(6)
          Text {
            text: "Paste this code on the GitHub page that just opened, then click Authorize:"
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.ff; font.pixelSize: Style.font.bodySmall
          }
          Row {
            spacing: Style.space(10)
            Text {
              id: codeText
              objectName: "userCode"
              anchors.verticalCenter: parent.verticalCenter
              text: PlugStore.userCode
              textFormat: Text.PlainText
              color: root.accent
              font.family: root.ff; font.pixelSize: Style.font.title + 10; font.bold: true; font.letterSpacing: 4
            }
            PanelActionButton {
              objectName: "copyCodeButton"
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{f018f}"
              tooltipText: "Copy the code"
              foreground: root.fg
              fontFamily: root.ff
              onClicked: { PlugStore.copy(PlugStore.userCode); root.codeCopied = true; copiedTimer.restart() }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.codeCopied
              text: "Copied"
              color: root.dim
              font.family: root.ff; font.pixelSize: Style.font.bodySmall
            }
          }
          Row {
            spacing: Style.space(6)
            Button {
              text: "Open GitHub again"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              fontSize: Style.font.bodySmall
              onClicked: { PlugStore.copy(PlugStore.userCode); PlugStore.openUrl(PlugStore.verifyUri) }
            }
            Button {
              text: "Cancel"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              fontSize: Style.font.bodySmall
              onClicked: PlugStore.cancelSignIn()
            }
          }
        }

        Column {
          visible: !PlugStore.signedIn && !(PlugStore.signingIn && PlugStore.userCode !== "")
          width: parent.width
          spacing: Style.space(6)
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Marketplace numbers work without this. Sign in to keep your clone and view history beyond GitHub's 14 days."
            color: root.dim
            font.family: root.ff; font.pixelSize: Style.font.bodySmall
          }
          Row {
            spacing: Style.space(6)
            Button {
              objectName: "signInButton"
              text: "Sign in with GitHub"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              enabled: PlugStore.keyringChecked && !PlugStore.signingIn
              onClicked: PlugStore.signIn()
            }
            Button {
              objectName: "tokenModeButton"
              text: root.tokenMode ? "Hide token" : "Use a token instead"
              foreground: root.dim
              fontFamily: root.ff
              fontSize: Style.font.bodySmall
              onClicked: root.tokenMode = !root.tokenMode
            }
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Read-only. GitHub files traffic under \"administration\"; the app can't change anything."
            color: root.dim
            font.family: root.ff; font.pixelSize: Style.font.caption
          }
          Column {
            visible: root.tokenMode
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "A fine-grained token with Repository permissions → Administration: Read-only, for the repos you track. Stored in the system keyring."
              color: root.dim
              font.family: root.ff; font.pixelSize: Style.font.caption
            }
            Row {
              width: parent.width
              spacing: Style.space(6)
              TextField {
                id: tokenField
                objectName: "tokenField"
                width: parent.width - saveToken.width - makeToken.width - Style.space(12)
                password: true
                foreground: root.fg
                placeholderText: "github_pat_…"
                onAccepted: root.saveToken()
              }
              Button {
                id: saveToken
                text: "Save"
                bordered: true
                foreground: root.fg
                fontFamily: root.ff
                onClicked: root.saveToken()
              }
              PanelActionButton {
                id: makeToken
                iconText: "\u{f059f}"
                tooltipText: "Create a token on GitHub"
                foreground: root.fg
                fontFamily: root.ff
                onClicked: PlugStore.openUrl(PlugStore.tokenHelpUrl)
              }
            }
          }
        }

        Text {
          visible: (PlugStore.authError || root.tokenError) !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.tokenError || PlugStore.authError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.ff; font.pixelSize: Style.font.bodySmall
        }

        // ── footer ──
        Text {
          visible: PlugStore.missed !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: "GitHub only keeps 14 days, so " + PlugStore.missed + " couldn't be read (the computer was off or the shell wasn't running)."
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.ff; font.pixelSize: Style.font.caption
        }
        Text {
          visible: PlugStore.pollError !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: PlugStore.pollError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.ff; font.pixelSize: Style.font.caption
        }
        Text {
          visible: root.hasRepos
          text: (PlugStore.polling ? "Checking…" : "Checked " + root.ago(PlugStore.state.lastPoll)) + " · every " + ({ hourly: "hour", daily: "day", weekly: "week", biweekly: "2 weeks" })[PlugStore.pollEvery]
          color: root.dim
          font.family: root.ff; font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ── milestone card over the blurred dropdown ────────────────────────
  Confetti {
    id: confetti
    anchors.fill: parent
    enabled: false
    z: 10
    glyphColor: root.accent
    fgColor: root.fg
    visible: running
  }

  Column {
    id: card
    objectName: "milestoneCard"
    z: 11
    anchors.centerIn: parent
    anchors.verticalCenterOffset: -Style.space(30)
    spacing: Style.space(6)
    enabled: false
    visible: opacity > 0
    opacity: root.cardOpacity
    scale: root.cardScale

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "MILESTONE"
      color: root.dim
      font.family: root.ff; font.pixelSize: Style.font.bodySmall; font.bold: true; font.letterSpacing: 3
    }
    DecryptText {
      id: cardNum
      anchors.horizontalCenter: parent.horizontalCenter
      settledColor: root.accent; scrambleColor: root.fg
      duration: root.anim ? 700 : 1
      font.family: root.ff; font.pixelSize: Style.font.title + 30; font.bold: true
    }
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: cardNum.implicitWidth * root.cardRule
      height: Style.space(2)
      color: root.accent
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: (Model.METRIC_LABELS[root.shownMetric] || "").toUpperCase()
      color: root.fg
      font.family: root.ff; font.pixelSize: Style.font.bodySmall; font.bold: true; font.letterSpacing: 2
    }
  }

  // Blur in, hold, then card and blur leave together (Omarchy easing: OutCubic).
  // Without animations the card simply shows and hides.
  SequentialAnimation {
    id: celebrateAnim
    ScriptAction { script: cardNum.play() }
    ParallelAnimation {
      NumberAnimation { target: root; property: "celebrate"; from: 0; to: 1; duration: root.anim ? 260 : 0; easing.type: Easing.OutCubic }
      NumberAnimation { target: root; property: "cardOpacity"; from: 0; to: 1; duration: root.anim ? 260 : 0; easing.type: Easing.OutCubic }
      NumberAnimation { target: root; property: "cardScale"; from: root.anim ? 0.94 : 1; to: 1; duration: root.anim ? 420 : 0; easing.type: Easing.OutCubic }
      NumberAnimation { target: root; property: "cardRule"; from: root.anim ? 0 : 1; to: 1; duration: root.anim ? 420 : 0; easing.type: Easing.OutCubic }
    }
    PauseAnimation { duration: 2800 }
    ParallelAnimation {
      NumberAnimation { target: root; property: "cardOpacity"; to: 0; duration: root.anim ? 420 : 0; easing.type: Easing.OutCubic }
      NumberAnimation { target: root; property: "celebrate"; to: 0; duration: root.anim ? 420 : 0; easing.type: Easing.InOutCubic }
    }
  }
}
