import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The HowIsMyPlug? dropdown. Pages: the overview (combined totals and the
// tracked repos), one page per repo (its own numbers, checks and milestones),
// settings and help. The panel has a fixed height; each page scrolls.
// `panel` is Panel.qml (settings); PlugStore holds the data.
Item {
  id: root

  property var panel: null
  property bool active: false
  // PanelKeyCatcher claims plain keys, so it stands down while a text field has focus.
  property int editorsFocused: 0
  readonly property bool editing: editorsFocused > 0

  readonly property string ff: panel ? panel.fontFamily : Style.font.family
  readonly property color fg: Color.popups.text
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.58)
  readonly property color accent: panel ? panel.accent : Color.accent
  readonly property bool anim: panel ? panel.animations : true
  readonly property string period: panel ? panel.period : "all"
  readonly property string mode: panel ? panel.countMode : "both"
  readonly property string today: Model.dayKey(PlugStore.now)
  readonly property bool hasRepos: PlugStore.repos.length > 0

  // ── navigation ──────────────────────────────────────────────────────
  property string page: "overview"     // overview | repo | settings | help
  property string currentRepo: ""
  readonly property var repo: page === "repo" ? Model.findRepo(PlugStore.repos, currentRepo) : null

  function openRepo(name) { currentRepo = name; go("repo") }
  function go(p) { page = p; flick.contentY = 0; confirmRemove = false }
  function back() {
    if (page === "overview") { if (panel) panel.close() }
    else go("overview")
  }
  // A removed repo's page closes itself.
  onRepoChanged: if (page === "repo" && !repo) Qt.callLater(function() { if (root.page === "repo" && !root.repo) root.go("overview") })

  readonly property var totals: Model.totalsFor(page === "repo" && repo ? [repo] : PlugStore.repos, period, today)

  property string repoError: ""
  property string tokenError: ""
  property bool tokenMode: false
  property bool codeCopied: false
  property bool confirmRemove: false
  Timer { id: confirmTimer; interval: 4000; onTriggered: root.confirmRemove = false }
  Timer { id: copiedTimer; interval: 2000; onTriggered: root.codeCopied = false }

  readonly property var checkOptions: [{ value: "hourly", label: "Hourly" }, { value: "daily", label: "Daily" },
                                       { value: "weekly", label: "Weekly" }, { value: "biweekly", label: "2 weeks" }]
  readonly property var metricOptions: Model.METRICS.map(function(m) {
    return { value: m, label: Model.METRIC_LABELS[m].charAt(0).toUpperCase() + Model.METRIC_LABELS[m].slice(1) }
  })

  function ago(ms) {
    if (!(ms > 0)) return "never"
    var s = (PlugStore.now - ms) / 1000
    if (s < 90) return "just now"
    if (s < 5400) return Math.round(s / 60) + " min ago"
    if (s < 172800) return Math.round(s / 3600) + " h ago"
    return Math.round(s / 86400) + " days ago"
  }

  function shortName(name) { return name.split("/")[1] || name }

  // One line under a repo in the overview list.
  function rowLine(r) {
    var parts = []
    if (r.access === "denied" || r.access === "missing") parts.push("needs access")
    else if (!PlugStore.signedIn) parts.push("sign in for clones")
    else if (r.clones) {
      var c = Model.trafficFor(r.clones, root.period, root.today), v = Model.trafficFor(r.views, root.period, root.today)
      parts.push(Model.grouped(root.mode === "unique" ? c.uniques : c.count) + " clones",
                 Model.grouped(root.mode === "unique" ? v.uniques : v.count) + " views")
    } else parts.push("waiting for GitHub")
    if (r.market) parts.push(Model.grouped(Model.marketFor(r.market, root.period, root.today).views) + " listing views")
    return parts.join("  ·  ")
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

  function saveToken(field) {
    root.tokenError = PlugStore.submitToken(field.text)
    field.text = ""
    if (!root.tokenError) root.tokenMode = false
  }

  function setRepoMilestone(change) {
    var m = { on: repo.milestone.on, metric: repo.milestone.metric, step: repo.milestone.step }
    for (var k in change) m[k] = change[k]
    PlugStore.setRepoOption(repo.repo, "milestone", m)
  }

  function save(values) { if (panel) panel.persistSettings(values) }

  // ── reveal + milestones ─────────────────────────────────────────────
  // Called each time the dropdown opens / closes.
  function reveal() {
    replay()
    Qt.callLater(checkMilestones)
  }
  // The numbers' reveal animation, on opening and on the refresh button.
  property int reveals: 0
  function replay() {
    reveals++
    if (root.anim) tiles.play()
  }
  function reset() {
    celebrateAnim.stop()
    queue = []
    root.celebrate = 0; root.cardOpacity = 0
    confetti.reset()
    go("overview")
  }

  property var queue: []                 // milestones waiting for their card
  property var shown: ({ repo: "", metric: "clones", value: 0 })
  property real celebrate: 0
  property real cardOpacity: 0
  property real cardScale: 1
  property real cardRule: 0

  function checkMilestones() {
    if (!root.active || !panel || !PlugStore.stateLoaded) return
    var found = PlugStore.takeMilestones(panel.combinedMilestone)
    if (found.length === 0) return
    queue = queue.concat(found)
    if (!celebrateAnim.running) showNext()
  }

  function showNext() {
    if (queue.length === 0) return
    shown = queue[0]
    queue = queue.slice(1)
    cardNum.target = Model.grouped(shown.value)
    if (root.anim) confetti.burst()
    celebrateAnim.restart()
  }

  // Numbers that arrive (and cross a milestone) while the dropdown is open count too.
  onTotalsChanged: if (active) Qt.callLater(checkMilestones)

  // ── header (fixed) ──────────────────────────────────────────────────
  Item {
    id: header
    z: 2
    anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
    height: Math.max(titleText.implicitHeight, helpButton.height)

    Row {
      anchors.left: parent.left
      anchors.right: actions.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
      PanelActionButton {
        id: backButton
        objectName: "backButton"
        visible: root.page !== "overview"
        anchors.verticalCenter: parent.verticalCenter
        iconText: "\u{f0141}"
        tooltipText: "Back"
        foreground: root.fg
        fontFamily: root.ff
        onClicked: root.back()
      }
      Text {
        id: titleText
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - (backButton.visible ? backButton.width + parent.spacing : 0)
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: root.page === "repo" && root.repo ? root.shortName(root.repo.repo)
            : root.page === "settings" ? "Settings" : root.page === "help" ? "Help" : "HowIsMyPlug?"
        color: root.fg
        font.family: root.ff; font.pixelSize: Style.font.title; font.bold: true
      }
    }
    Row {
      id: actions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      PanelActionButton {
        objectName: "refreshButton"
        iconText: "\u{f0450}"
        tooltipText: PlugStore.polling ? "Checking…" : "Check everything now"
        foreground: root.fg
        fontFamily: root.ff
        enabled: !PlugStore.polling
        onClicked: { PlugStore.pollNow(); root.replay() }
      }
      PanelActionButton {
        objectName: "settingsButton"
        iconText: "\u{f0493}"
        tooltipText: "Settings"
        foreground: root.page === "settings" ? root.accent : root.fg
        fontFamily: root.ff
        onClicked: root.page === "settings" ? root.go("overview") : root.go("settings")
      }
      PanelActionButton {
        id: helpButton
        objectName: "helpButton"
        iconText: "\u{f02d7}"
        tooltipText: "Help and setup steps"
        foreground: root.page === "help" ? root.accent : root.fg
        fontFamily: root.ff
        onClicked: root.page === "help" ? root.go("overview") : root.go("help")
      }
    }
  }

  // ── pages (scroll inside the fixed panel) ───────────────────────────
  Item {
    id: scene
    anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: parent.bottom; topMargin: Style.space(10) }
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
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.bottomMargin: Style.space(10)
      contentHeight: col.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: col
        width: flick.width
        spacing: Style.space(10)

        // ═════════ overview + repo: period and numbers ═════════
        ChoiceRow {
          objectName: "periodChoice"
          visible: root.page === "overview" || root.page === "repo"
          options: [{ value: "7d", label: "7 days" }, { value: "14d", label: "14 days" }, { value: "30d", label: "30 days" }, { value: "all", label: "All time" }]
          value: root.period
          onPicked: function(v) { root.save({ period: v }) }
        }

        StatTiles {
          id: tiles
          visible: root.hasRepos && (root.page === "repo" || (root.page === "overview" && (!root.panel || root.panel.showCombined)))
          totals: root.totals
        }

        Text {
          visible: root.hasRepos && root.mode !== "total" && PlugStore.signedIn && (root.page === "overview" || root.page === "repo")
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.period === "14d" ? "Unique is GitHub's own count for its latest 14 days."
              : "Unique: GitHub's 14-day number when tracking started, plus each new day's unique people. Tap ? for more."
          color: root.dim
          font.family: root.ff; font.pixelSize: Style.font.caption
        }

        // ═════════ overview: tracked repos ═════════
        PanelSeparator { visible: root.page === "overview"; width: parent.width; foreground: root.fg }
        PanelSectionHeader {
          visible: root.page === "overview"
          text: "TRACKING" + (root.hasRepos ? " (" + PlugStore.repos.length + ")" : "")
          foreground: root.fg; fontFamily: root.ff
        }
        Text {
          visible: root.page === "overview" && !root.hasRepos
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Add a repo you own below. Plugin repos also show their marketplace listing. New here? Tap ? for the 1-minute setup."
          color: root.dim
          font.family: root.ff; font.pixelSize: Style.font.bodySmall
        }
        Repeater {
          model: root.page === "overview" ? PlugStore.repos : []
          delegate: Item {
            required property var modelData
            objectName: "repoRow-" + modelData.repo
            width: col.width
            height: rowCol.implicitHeight + Style.space(8)
            function clicked() { root.openRepo(modelData.repo) }
            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: rowMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06) : "transparent"
            }
            Column {
              id: rowCol
              anchors { left: parent.left; right: chevron.left; verticalCenter: parent.verticalCenter; leftMargin: Style.space(4) }
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: modelData.repo
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.fg
                font.family: root.ff; font.pixelSize: Style.font.body; font.bold: true
              }
              Text {
                width: parent.width
                text: root.rowLine(modelData)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: (modelData.access === "denied" || modelData.access === "missing") ? Color.urgent : root.dim
                font.family: root.ff; font.pixelSize: Style.font.bodySmall
              }
            }
            Text {
              id: chevron
              anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: Style.space(4) }
              text: "\u{f0142}"
              color: root.dim
              font.family: root.ff; font.pixelSize: Style.font.icon
            }
            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: parent.clicked()
            }
          }
        }
        Row {
          visible: root.page === "overview"
          width: parent.width
          spacing: Style.space(6)
          TextField {
            id: repoField
            objectName: "repoField"
            width: parent.width - trackButton.width - Style.space(6)
            foreground: root.fg
            accent: root.accent
            placeholderText: "e.g. yourname/my-omarchy-plugin"
            onActiveFocusChanged: root.editorsFocused += activeFocus ? 1 : -1
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
          visible: root.page === "overview" && root.repoError !== ""
          text: root.repoError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.ff; font.pixelSize: Style.font.bodySmall
        }

        // Signed out, the sign-in sits on the overview where it can't be missed.
        SignInBlock { objectName: "overviewSignIn"; visible: root.page === "overview" && !PlugStore.signedIn }

        // ═════════ repo page ═════════
        Column {
          objectName: "repoPage"
          visible: root.page === "repo" && root.repo !== null
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: !root.repo ? "" : root.repo.repo + (root.repo.pluginId ? "  ·  " + root.repo.pluginId
                  : (root.repo.idChecked ? "  ·  not a plugin repo" : ""))
            color: root.dim
            font.family: root.ff; font.pixelSize: Style.font.caption
          }
          Column {
            visible: !!root.repo && (root.repo.access === "denied" || root.repo.access === "missing")
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "The HowIsMyPlug app can't see this repo's traffic yet. Give it access on GitHub (you must own the repo)."
              color: Color.urgent
              font.family: root.ff; font.pixelSize: Style.font.bodySmall
            }
            Button {
              objectName: "giveAccessButton"
              text: "Give access"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              onClicked: PlugStore.openUrl(PlugStore.installUrl)
            }
          }
          Text {
            visible: !!root.repo && root.repo.missed !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: !root.repo ? "" : "GitHub only keeps 14 days, so " + root.repo.missed + " couldn't be read (the computer was off or the shell wasn't running)."
            color: Color.urgent
            font.family: root.ff; font.pixelSize: Style.font.caption
          }

          PanelSectionHeader { text: "CHECKS"; foreground: root.fg; fontFamily: root.ff }
          ChoiceRow {
            objectName: "repoCheckGithub"
            label: "Check GitHub traffic" + (root.repo && root.repo.lastGithub ? " · last " + root.ago(root.repo.lastGithub) : "")
            options: root.checkOptions
            value: root.repo ? root.repo.checkGithub : "daily"
            onPicked: function(v) { PlugStore.setRepoOption(root.repo.repo, "checkGithub", v) }
          }
          ChoiceRow {
            objectName: "repoCheckListing"
            visible: !!root.repo && root.repo.pluginId !== ""
            label: "Check the listing" + (root.repo && root.repo.lastListing ? " · last " + root.ago(root.repo.lastListing) : "")
            options: root.checkOptions
            value: root.repo ? root.repo.checkListing : "daily"
            onPicked: function(v) { PlugStore.setRepoOption(root.repo.repo, "checkListing", v) }
          }

          PanelSectionHeader { text: "MILESTONES"; foreground: root.fg; fontFamily: root.ff }
          SettingToggle {
            objectName: "repoMilestonesToggle"
            label: "Celebrate this repo's milestones"
            checked: !!root.repo && root.repo.milestone.on
            onClicked: root.setRepoMilestone({ on: !root.repo.milestone.on })
          }
          MilestoneRow {
            visible: !!root.repo && root.repo.milestone.on
            prefix: "repo"
            metric: root.repo ? root.repo.milestone.metric : "clones"
            step: root.repo ? root.repo.milestone.step : 100
            onMetricPicked: function(v) { root.setRepoMilestone({ metric: v }) }
            onStepPicked: function(v) { root.setRepoMilestone({ step: v }) }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            Button {
              text: "Open on GitHub"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              fontSize: Style.font.bodySmall
              onClicked: PlugStore.openRepoPage(root.repo.repo)
            }
            Button {
              visible: !!root.repo && root.repo.market !== null
              text: "Open listing"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              fontSize: Style.font.bodySmall
              onClicked: PlugStore.openListing(root.repo.pluginId)
            }
            // Removing deletes the repo's saved history, so it takes a second click.
            Button {
              objectName: "removeRepoButton"
              text: root.confirmRemove ? "Click again: delete its history" : "Stop tracking"
              bordered: true
              foreground: Color.urgent
              fontFamily: root.ff
              fontSize: Style.font.bodySmall
              onClicked: {
                if (!root.confirmRemove) { root.confirmRemove = true; confirmTimer.restart(); return }
                root.confirmRemove = false
                PlugStore.removeRepo(root.repo.repo)
              }
            }
          }
        }

        // ═════════ settings page ═════════
        Column {
          objectName: "settingsPage"
          visible: root.page === "settings"
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader { text: "BAR"; foreground: root.fg; fontFamily: root.ff }
          Dropdown {
            objectName: "barSourceChoice"
            width: parent.width
            label: "Number in the bar comes from"
            foreground: root.fg; accent: root.accent; fontFamily: root.ff
            options: [{ value: "all", label: "All repos combined" }].concat(PlugStore.repos.map(function(r) { return { value: r.repo, label: r.repo } }))
            value: root.panel ? root.panel.barSource : "all"
            onChanged: function(v) { root.save({ barSource: v }) }
          }
          Dropdown {
            objectName: "barStatChoice"
            width: parent.width
            label: "Number in the bar shows"
            foreground: root.fg; accent: root.accent; fontFamily: root.ff
            options: root.metricOptions
            value: root.panel ? root.panel.barStat : "clones"
            onChanged: function(v) { root.save({ barStat: v }) }
          }

          PanelSectionHeader { text: "LOOK"; foreground: root.fg; fontFamily: root.ff }
          ChoiceRow {
            objectName: "panelSizeChoice"
            label: "Dropdown size"
            options: [{ value: "compact", label: "Compact" }, { value: "normal", label: "Normal" }, { value: "tall", label: "Tall" }]
            value: root.panel ? root.panel.panelSize : "normal"
            onPicked: function(v) { root.save({ panelSize: v }) }
          }
          ChoiceRow {
            objectName: "accentChoice"
            label: "Highlight colour (from your theme)"
            options: [{ value: "theme", label: "Accent" }, { value: "foreground", label: "Text" }, { value: "urgent", label: "Alert" }]
            value: root.panel ? root.panel.accentRole : "theme"
            onPicked: function(v) { root.save({ accent: v }) }
          }
          ChoiceRow {
            objectName: "countModeChoice"
            label: "Clones and views"
            options: [{ value: "total", label: "Total" }, { value: "unique", label: "Unique" }, { value: "both", label: "Both" }]
            value: root.mode
            onPicked: function(v) { root.save({ countMode: v }) }
          }
          SettingToggle {
            objectName: "animationsToggle"
            label: "Animations"
            description: "Number reveals, falling digits, confetti, the glowing bar icon"
            checked: root.anim
            onClicked: root.save({ animations: !root.anim })
          }
          SettingToggle {
            objectName: "showCombinedToggle"
            label: "Show combined totals"
            description: "All repos added up, at the top of the overview"
            checked: !root.panel || root.panel.showCombined
            onClicked: root.save({ showCombined: !root.panel.showCombined })
          }

          PanelSectionHeader { text: "COMBINED MILESTONES"; foreground: root.fg; fontFamily: root.ff }
          SettingToggle {
            objectName: "combinedMilestonesToggle"
            label: "Celebrate all repos added up"
            description: "Each repo's own milestones are set on its page"
            checked: !root.panel || root.panel.combinedMilestone.on
            onClicked: root.save({ combinedMilestones: !root.panel.combinedMilestone.on })
          }
          MilestoneRow {
            visible: !root.panel || root.panel.combinedMilestone.on
            prefix: "combined"
            metric: root.panel ? root.panel.combinedMilestone.metric : "clones"
            step: root.panel ? root.panel.combinedMilestone.step : 100
            onMetricPicked: function(v) { root.save({ milestoneMetric: v }) }
            onStepPicked: function(v) { root.save({ milestoneStep: v }) }
          }

          PanelSectionHeader { text: "NEW REPOS START WITH"; foreground: root.fg; fontFamily: root.ff }
          ChoiceRow {
            objectName: "defaultCheckGithubChoice"
            label: "Check GitHub traffic"
            options: root.checkOptions
            value: root.panel ? root.panel.defaultCheckGithub : "daily"
            onPicked: function(v) { root.save({ defaultCheckGithub: v }) }
          }
          ChoiceRow {
            objectName: "defaultCheckListingChoice"
            label: "Check the listing"
            options: root.checkOptions
            value: root.panel ? root.panel.defaultCheckListing : "daily"
            onPicked: function(v) { root.save({ defaultCheckListing: v }) }
          }

          PanelSectionHeader { visible: PlugStore.signedIn; text: "GITHUB"; foreground: root.fg; fontFamily: root.ff }
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
          SignInBlock { objectName: "settingsSignIn"; visible: !PlugStore.signedIn }
        }

        // ═════════ help page ═════════
        Column {
          objectName: "helpPage"
          visible: root.page === "help"
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader { text: "SET UP IN A MINUTE"; foreground: root.fg; fontFamily: root.ff }
          HelpStep { n: "1"; body: "On the overview, type a repo you own (like yourname/my-omarchy-plugin) and press Track. Marketplace numbers show right away." }
          HelpStep { n: "2"; body: "Click Sign in with GitHub. A code is copied and GitHub opens." }
          HelpStep { n: "3"; body: "Paste the code (or type it), click Continue, then Authorize HowIsMyPlug." }
          HelpStep { n: "4"; body: "Click Give access, pick your account, choose All repositories (or just your plugin repos) and click Install." }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "That's it. Clones and views fill in within seconds and are kept from then on."
            color: root.fg
            font.family: root.ff; font.pixelSize: Style.font.bodySmall
          }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Button {
              objectName: "helpSignIn"
              visible: !PlugStore.signedIn
              text: "Sign in with GitHub"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              fontSize: Style.font.bodySmall
              enabled: PlugStore.keyringChecked && !PlugStore.signingIn
              onClicked: { PlugStore.signIn(); root.go("overview") }
            }
            Button {
              objectName: "helpGiveAccess"
              text: "Give access"
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              fontSize: Style.font.bodySmall
              onClicked: PlugStore.openUrl(PlugStore.installUrl)
            }
          }

          PanelSectionHeader { text: "RATHER USE A TOKEN?"; foreground: root.fg; fontFamily: root.ff }
          HelpStep { n: "1"; body: "Open GitHub's new fine-grained token page (button below)." }
          HelpStep { n: "2"; body: "Name it, then Repository access → Only select repositories → pick your plugin repos." }
          HelpStep { n: "3"; body: "Permissions → Repository permissions → Administration → Read-only. Nothing else." }
          HelpStep { n: "4"; body: "Generate token and copy it. Back here, click Use a token instead (under Sign in) and paste it." }
          Button {
            objectName: "helpTokenPage"
            text: "Open the token page"
            bordered: true
            foreground: root.fg
            fontFamily: root.ff
            fontSize: Style.font.bodySmall
            onClicked: PlugStore.openUrl(PlugStore.tokenHelpUrl)
          }

          PanelSectionHeader { text: "WHAT THE NUMBERS MEAN"; foreground: root.fg; fontFamily: root.ff }
          HelpStep { n: "·"; body: "Clones: git clones of the repo, which includes every omarchy plugin add and update." }
          HelpStep { n: "·"; body: "Repo views: visits to the repo's pages on GitHub." }
          HelpStep { n: "·"; body: "Listing views, copies, hearts: your marketplace listing's own counts. Copies are clicks on its copy-install button." }
          HelpStep { n: "·"; body: "Unique: different people, as GitHub counts them. Lifetime starts with GitHub's 14-day number when you start tracking, then adds each new day's unique number (100 at the start + 20 over the next days = 120). 14 days shows GitHub's own number, the same as its traffic page." }
          HelpStep { n: "·"; body: "GitHub's window rolls: each day a new day comes in and the oldest drops out. Every day is saved before it drops out, so nothing is lost unless the computer is off for more than 14 days in a row (the dropdown then says which days)." }
          HelpStep { n: "·"; body: "Read-only: GitHub files traffic under \"administration\". The app can't change anything, and you can revoke it in GitHub → Settings → Applications." }
        }

        // ═════════ footer (overview) ═════════
        Text {
          visible: root.page === "overview" && PlugStore.pollError !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          text: PlugStore.pollError
          textFormat: Text.PlainText
          color: Color.urgent
          font.family: root.ff; font.pixelSize: Style.font.caption
        }
        Text {
          visible: root.page === "overview" && root.hasRepos
          width: parent.width
          wrapMode: Text.WordWrap
          text: PlugStore.polling ? "Checking…" : "Checked " + root.ago(PlugStore.state.lastPoll) + " · tap a repo for its own settings"
          color: root.dim
          font.family: root.ff; font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // ── milestone card over the blurred dropdown ────────────────────────
  Confetti {
    id: confetti
    objectName: "confetti"
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
      text: (Model.METRIC_LABELS[root.shown.metric] || "").toUpperCase()
      color: root.fg
      font.family: root.ff; font.pixelSize: Style.font.bodySmall; font.bold: true; font.letterSpacing: 2
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.shown.repo === "" ? "ALL REPOS" : root.shortName(root.shown.repo).toUpperCase()
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.ff; font.pixelSize: Style.font.caption; font.letterSpacing: 2
    }
  }

  // Blur in, hold, then card and blur leave together (Omarchy easing: OutCubic);
  // then the next milestone, if several were crossed. Without animations the
  // card simply shows and hides.
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
    ScriptAction { script: root.showNext() }
  }

  // ── building blocks ─────────────────────────────────────────────────
  component ChoiceRow: Column {
    id: choice
    property string label: ""
    property alias options: group.options
    property alias value: group.value
    signal picked(string value)
    width: parent ? parent.width : 0
    spacing: Style.space(6)
    Text {
      visible: choice.label !== ""
      width: parent.width
      elide: Text.ElideRight
      text: choice.label
      color: root.dim
      font.family: root.ff; font.pixelSize: Style.font.caption
    }
    ButtonGroup {
      id: group
      objectName: choice.objectName + "Group"
      focusable: false
      foreground: root.fg
      accent: root.accent
      fontFamily: root.ff
      fontSize: Style.font.bodySmall
      onChanged: function(value) { choice.picked(value) }
    }
  }

  component SettingToggle: Toggle {
    width: parent ? parent.width : 0
    foreground: root.fg
    accent: root.accent
    fontFamily: root.ff
    titleSize: Style.font.body
  }

  component MilestoneRow: Row {
    id: ms
    property string prefix: ""
    property string metric: "clones"
    property int step: 100
    signal metricPicked(string value)
    signal stepPicked(int value)
    width: parent ? parent.width : 0
    spacing: Style.space(10)
    Dropdown {
      objectName: ms.prefix + "MilestoneMetric"
      width: parent.width - stepField.width - Style.space(10)
      label: "Count"
      foreground: root.fg; accent: root.accent; fontFamily: root.ff
      options: root.metricOptions
      value: ms.metric
      onChanged: function(v) { ms.metricPicked(v) }
    }
    NumberField {
      id: stepField
      objectName: ms.prefix + "MilestoneStep"
      label: "Every"
      from: 1; to: 1000000
      stepSize: ms.step >= 1000 ? 100 : (ms.step >= 100 ? 10 : 1)
      value: ms.step
      foreground: root.fg; accent: root.accent; fontFamily: root.ff
      onModified: function(v) { ms.stepPicked(v) }
    }
  }

  component HelpStep: Row {
    id: step
    property string n: ""
    property string body: ""
    width: parent ? parent.width : 0
    spacing: Style.space(8)
    Text {
      id: num
      width: Style.space(16)
      text: step.n
      color: root.accent
      font.family: root.ff; font.pixelSize: Style.font.body; font.bold: true
    }
    Text {
      width: step.width - num.width - step.spacing
      wrapMode: Text.WordWrap
      text: step.body
      color: root.fg
      font.family: root.ff; font.pixelSize: Style.font.bodySmall
    }
  }

  component StatTiles: Grid {
    id: grid
    property var totals: null
    function play() { for (var i = 0; i < reps.count; i++) reps.itemAt(i).play() }
    width: parent ? parent.width : 0
    columns: 2
    columnSpacing: Style.space(10)
    rowSpacing: Style.space(10)
    Repeater {
      id: reps
      model: !grid.totals ? [] : [
        { label: "CLONES", value: root.big(grid.totals.clones), sub: root.sub(grid.totals.clones) },
        { label: "REPO VIEWS", value: root.big(grid.totals.views), sub: root.sub(grid.totals.views) },
        { label: "LISTING VIEWS", value: Model.grouped(grid.totals.market.views), sub: "" },
        { label: "COPIES · HEARTS", value: Model.grouped(grid.totals.market.copies) + " · " + Model.grouped(grid.totals.market.hearts), sub: "" }
      ]
      delegate: Column {
        required property var modelData
        width: (grid.width - grid.columnSpacing) / 2
        spacing: Style.space(2)
        function play() { tileNum.play() }
        Text {
          text: modelData.label
          color: root.dim
          font.family: root.ff; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.5
        }
        DecryptText {
          id: tileNum
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

  component SignInBlock: Column {
    id: signIn
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    PanelSeparator { width: parent.width; foreground: root.fg }
    PanelSectionHeader { text: "GITHUB"; foreground: root.fg; fontFamily: root.ff }

    Column {
      visible: PlugStore.signingIn && PlugStore.userCode !== ""
      width: parent.width
      spacing: Style.space(6)
      Text {
        text: "Paste this code on the GitHub page that just opened, then click Continue and Authorize:"
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.dim
        font.family: root.ff; font.pixelSize: Style.font.bodySmall
      }
      Row {
        spacing: Style.space(10)
        Text {
          objectName: signIn.objectName + "-userCode"
          anchors.verticalCenter: parent.verticalCenter
          text: PlugStore.userCode
          textFormat: Text.PlainText
          color: root.accent
          font.family: root.ff; font.pixelSize: Style.font.title + 10; font.bold: true; font.letterSpacing: 4
        }
        PanelActionButton {
          objectName: signIn.objectName + "-copyCode"
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
      visible: !(PlugStore.signingIn && PlugStore.userCode !== "")
      width: parent.width
      spacing: Style.space(6)
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: "Marketplace numbers work without this. Sign in to keep your clone and view history beyond GitHub's 14 days."
        color: root.dim
        font.family: root.ff; font.pixelSize: Style.font.bodySmall
      }
      Flow {
        width: parent.width
        spacing: Style.space(6)
        Button {
          objectName: signIn.objectName + "-signIn"
          text: "Sign in with GitHub"
          bordered: true
          foreground: root.fg
          fontFamily: root.ff
          enabled: PlugStore.keyringChecked && !PlugStore.signingIn
          onClicked: PlugStore.signIn()
        }
        Button {
          objectName: signIn.objectName + "-tokenMode"
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
        text: "Read-only. GitHub files traffic under \"administration\"; the app can't change anything. Step-by-step: tap ?"
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
          text: "A fine-grained token with Repository permissions → Administration: Read-only. Kept in the system keyring."
          color: root.dim
          font.family: root.ff; font.pixelSize: Style.font.caption
        }
        Row {
          width: parent.width
          spacing: Style.space(6)
          TextField {
            id: tokenField
            objectName: signIn.objectName + "-tokenField"
            width: parent.width - saveTokenButton.width - makeToken.width - Style.space(12)
            password: true
            foreground: root.fg
            accent: root.accent
            placeholderText: "github_pat_…"
            onActiveFocusChanged: root.editorsFocused += activeFocus ? 1 : -1
            onAccepted: root.saveToken(tokenField)
          }
          Button {
            id: saveTokenButton
            text: "Save"
            bordered: true
            foreground: root.fg
            fontFamily: root.ff
            onClicked: root.saveToken(tokenField)
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
  }
}
