#!/usr/bin/env python3
"""Run the HowIsMyPlug? bar widget outside a Wayland session.

Loads the real plugin entry point together with Omarchy's real Commons/Ui
components, backed by the minimal Quickshell stand-ins in qsmock/. Processes
run for real, so tests put a fake `secret-tool` first on PATH, and
HOWISMYPLUG_TEST_BASE points every web request at a local fake server.
URLs the plugin opens are recorded, never opened.

Examples:
    main.py --shot panel.png --theme tokyo-night          # render the dropdown
    main.py --dump state.json --do 'track:octo/plugin'    # drive it, then read state
"""

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

sys.path.insert(0, str(HERE))

from PySide6.QtCore import Q_ARG, QMetaObject, QObject, Qt, QTimer, QUrl, Slot  # noqa: E402
from PySide6.QtGui import QBitmap, QColor, QDesktopServices, QGuiApplication, QImage, QPainter, QRegion  # noqa: E402
from PySide6.QtQml import QJSValue, QQmlApplicationEngine, QQmlEngine, QQmlExpression  # noqa: E402
from PySide6.QtQuick import QQuickItem, QQuickWindow  # noqa: E402

from qsmock import core, hyprland, io, pipewire, wayland  # noqa: E402,F401  (import registers the QML types)


def build_import_root(omarchy_shell: Path) -> Path:
    """Expose Omarchy's Commons/Ui as the `qs.*` module namespace they expect."""
    root = HERE / ".qsroot"
    (root / "qs").mkdir(parents=True, exist_ok=True)
    for name in ("Commons", "Ui"):
        link = root / "qs" / name
        target = omarchy_shell / name
        if not target.is_dir():
            raise SystemExit(
                f"missing {target}; pass --omarchy <path to omarchy/shell>"
            )
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(target)
    # A system-wide Quickshell install puts its real modules on Qt's import
    # path; these plugin-less qmldirs win, so the qsmock registrations are used.
    for module in ("Quickshell", "Quickshell.Io", "Quickshell.Wayland", "Quickshell.Hyprland", "Quickshell.Services.Pipewire"):
        directory = root.joinpath(*module.split("."))
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "qmldir").write_text(f"module {module}\n")
    return root


def apply_theme(theme: Path, font_size: int) -> None:
    """Point HOME at a throwaway Omarchy config so the panel renders themed.

    Color and Style read the active theme and `[font] base-size` from the
    user's home directory, so screenshots are only representative if those
    files exist.
    """
    if not theme.is_dir():
        raise SystemExit(f"no such theme: {theme}")
    home = Path(tempfile.mkdtemp(prefix="omarchy-home-"))
    current = home / ".local" / "state" / "omarchy" / "current"
    current.mkdir(parents=True)
    (current / "theme").symlink_to(theme)
    config = home / ".config" / "omarchy"
    config.mkdir(parents=True)
    (config / "shell.toml").write_text(f"[font]\nbase-size = {font_size}\n")
    os.environ["HOME"] = str(home)


STORE_PROPS = (
    "stateLoaded",
    "keyringChecked",
    "signedIn",
    "authMethod",
    "signingIn",
    "userCode",
    "verifyUri",
    "authError",
    "polling",
    "pollError",
    "pollEvery",
)
PANEL_PROPS = ("nativeLabel", "width", "height", "opened", "period", "countMode", "barStat", "barText", "barValue", "milestonePending", "disco", "animations")
VIEW_PROPS = ("reveals", "page", "currentRepo", "shown", "codeCopied", "repoError", "tokenError", "tokenMode", "cardOpacity", "editing")

# URLs the plugin asked the desktop to open, recorded instead of opened.
OPENED: list[str] = []


class UrlRecorder(QObject):
    @Slot(QUrl)
    def open(self, url):
        OPENED.append(url.toString())


def read(obj: QObject, name: str, default=None):
    value = obj.property(name)
    # QML `var` properties holding JS values arrive as QJSValue.
    if isinstance(value, QJSValue):
        value = value.toVariant()
    return default if value is None else value


def snapshot(plugin: QObject, store: QObject) -> dict:
    state = {name: read(store, name) for name in STORE_PROPS}
    state["state"] = read(store, "state", {})
    state["panel"] = {name: read(plugin, name) for name in PANEL_PROPS}
    state["panel"]["settings"] = read(plugin, "settings", {})
    view = plugin.findChild(QObject, "plugView")
    state["view"] = {name: read(view, name) for name in VIEW_PROPS} if view else {}
    state["view"]["totals"] = read(view, "totals", {}) if view else {}
    # What the bar shows beside the plug, whichever way this Omarchy draws it.
    button = find_or_none(plugin, "barButton")
    number = find_or_none(plugin, "barNumber")
    if read(plugin, "nativeLabel"):
        state["panel"]["barShown"] = read(button, "labelText", "") if button else ""
    else:
        state["panel"]["barShown"] = read(number, "text", "") if number and number.property("visible") else ""
    state["panel"]["slotSize"] = read(button, "slotSize") if button else None
    confetti = plugin.findChild(QObject, "confetti")
    state["view"]["confetti"] = bool(confetti and confetti.property("running"))
    card = plugin.findChild(QObject, "milestoneCard")
    state["view"]["cardVisible"] = bool(card and card.property("visible"))
    keyboard = plugin.findChild(QObject, "keyboardPanel")
    state["panel"]["contentHeight"] = read(keyboard, "contentHeight") if keyboard else None
    bar = plugin.property("bar")
    state["barWrites"] = read(bar, "writes", []) if bar is not None else []
    state["detached"] = core.DETACHED
    state["piped"] = io.PIPED
    state["opened"] = OPENED
    return state


def invoke(obj: QObject, name: str, *args):
    """Call a QML-declared function. Its parameters arrive as QVariant."""
    return QMetaObject.invokeMethod(
        obj, name, Qt.DirectConnection, *[Q_ARG("QVariant", arg) for arg in args]
    )


def evaluate(obj: QObject, call: str):
    """Run a QML expression in an object's own context (its functions aren't
    reachable from Python attributes or the metaobject)."""
    expression = QQmlExpression(QQmlEngine.contextForObject(obj), obj, call)
    result = expression.evaluate()
    if expression.hasError():
        print(expression.error().toString(), file=sys.stderr)
    return result


def find(root: QObject, name: str):
    """findChild, plus the visual tree: Repeater delegates have a visual
    parent but not always a QObject one."""
    found = root.findChild(QObject, name)
    if found is not None:
        return found
    pending = [root]
    while pending:
        obj = pending.pop()
        if obj.objectName() == name:
            return obj
        pending.extend(obj.children())
        if isinstance(obj, QQuickItem):
            pending.extend(obj.childItems())
        elif isinstance(obj, QQuickWindow):
            pending.append(obj.contentItem())
    raise SystemExit(f"no object named {name!r}")


def find_or_none(root: QObject, name: str):
    try:
        return find(root, name)
    except SystemExit:
        return None


def apply_step(step: str, plugin: QObject, store: QObject, harness=None):
    """Run one scripted interaction, named the way a user would describe it."""
    name, _, argument = step.partition(":")
    view = plugin.findChild(QObject, "plugView")
    simple = {
        "open": (plugin, "open"),
        "close": (plugin, "close"),
        "sign-in": (store, "signIn"),
        "sign-out": (store, "signOut"),
        "cancel-sign-in": (store, "cancelSignIn"),
        "poll": (store, "pollNow"),
    }
    if name in simple:
        invoke(*simple[name])
    elif name == "track":
        find(plugin, "repoField").setProperty("text", argument)
        evaluate(view, "addRepo()")
    elif name == "untrack":
        invoke(store, "removeRepo", argument)
    elif name == "token":
        view.setProperty("tokenMode", True)
        field = find(plugin, "overviewSignIn-tokenField")
        field.setProperty("text", argument)
        QMetaObject.invokeMethod(field, "accepted")
    elif name == "open-repo":
        evaluate(view, "openRepo(" + json.dumps(argument) + ")")
    elif name == "page":
        evaluate(view, "go(" + json.dumps(argument) + ")")
    elif name in ("period", "pick"):
        # A ButtonGroup choice, as if clicked: pick:<ChoiceRow objectName>=<value>
        control, _, value = ("periodChoice", "", argument) if name == "period" else argument.partition("=")
        QMetaObject.invokeMethod(find(plugin, control + "Group"), "changed", Q_ARG("QString", value))
    elif name == "choose":
        # A Dropdown choice: choose:<objectName>=<value>
        control, _, value = argument.partition("=")
        QMetaObject.invokeMethod(find(plugin, control), "changed", Q_ARG("QString", value))
    elif name == "number":
        control, _, value = argument.partition("=")
        QMetaObject.invokeMethod(find(plugin, control), "modified", Q_ARG(int, int(value)))
    elif name == "reduce-motion":
        # The animation switch Omarchy 4.5 added, as its toggle sets it.
        evaluate(plugin, "Style.reduceMotion = true")
    elif name == "click":
        QMetaObject.invokeMethod(find(plugin, argument), "clicked")
    elif name == "wait":
        pass
    else:
        raise SystemExit(f"unknown step: {step}")


def compose(background: str) -> QImage:
    """Flatten every visible window into one image, largest first."""
    windows = [w for w in QGuiApplication.topLevelWindows() if w.isVisible()]
    grabs = []
    for window in windows:
        grab = window.grabWindow() if hasattr(window, "grabWindow") else None
        if grab is not None and not grab.isNull():
            grabs.append((window, grab))
    if not grabs:
        raise SystemExit("nothing visible to capture")

    width = max(w.x() + g.width() for w, g in grabs)
    height = max(w.y() + g.height() for w, g in grabs)
    canvas = QImage(width, height, QImage.Format_ARGB32_Premultiplied)
    canvas.fill(QColor(background))

    painter = QPainter(canvas)
    for window, grab in sorted(
        grabs, key=lambda pair: -(pair[1].width() * pair[1].height())
    ):
        painter.drawImage(window.x(), window.y(), grab)
    painter.end()
    return canvas


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--omarchy", default=os.environ.get("OMARCHY_SHELL", "/usr/share/omarchy/shell")
    )
    parser.add_argument("--plugin", default=str(REPO / "Panel.qml"))
    parser.add_argument(
        "--settings", default="{}", help="inline widget settings as JSON"
    )
    parser.add_argument("--shot", help="write a PNG of the rendered bar and panel")
    parser.add_argument("--panel-shot", help="write a PNG of the dropdown alone")
    parser.add_argument("--dump", help="write observed state as JSON")
    parser.add_argument("--open", dest="open_panel", action="store_true", default=True)
    parser.add_argument("--closed", dest="open_panel", action="store_false")
    parser.add_argument(
        "--settle",
        type=int,
        default=2500,
        help="ms to let the client answer before capturing",
    )
    parser.add_argument("--background", default="#0b0e12")
    parser.add_argument(
        "--theme", help="Omarchy theme name to render with, e.g. tokyo-night"
    )
    parser.add_argument(
        "--font-size",
        type=int,
        default=12,
        help="Omarchy [font] base-size for --theme runs",
    )
    parser.add_argument(
        "--do",
        default="",
        help="comma-separated interactions, e.g. 'call:0,wait:1200,mute'",
    )
    parser.add_argument(
        "--dump-each", help="directory for a state dump after every interaction"
    )
    parser.add_argument(
        "--step-delay", type=int, default=900, help="ms between interactions"
    )
    args = parser.parse_args()

    omarchy_shell = Path(args.omarchy).expanduser().resolve()
    import_root = build_import_root(omarchy_shell)
    if args.theme:
        apply_theme(omarchy_shell.parent / "themes" / args.theme, args.font_size)

    app = QGuiApplication(sys.argv[:1])
    recorder = UrlRecorder()
    for scheme in ("https", "http"):
        QDesktopServices.setUrlHandler(scheme, recorder, "open")
    engine = QQmlApplicationEngine()
    engine.addImportPath(str(import_root))
    engine.addImportPath(str(HERE / "qml"))

    engine.setInitialProperties(
        {
            "pluginUrl": QUrl.fromLocalFile(str(Path(args.plugin).resolve())),
            "pluginSettings": json.loads(args.settings),
        }
    )
    engine.warnings.connect(
        lambda warnings: [print(w.toString(), file=sys.stderr) for w in warnings]
    )
    engine.load(QUrl.fromLocalFile(str(HERE / "qml" / "Harness.qml")))
    if not engine.rootObjects():
        return 2

    harness = engine.rootObjects()[0]
    status = {"code": 0}

    def capture():
        plugin = harness.property("plugin")
        if plugin is None:
            print("plugin failed to load", file=sys.stderr)
            status["code"] = 3
            app.quit()
            return
        store = harness.property("store")

        try:
            if args.dump:
                state = snapshot(plugin, store)
                Path(args.dump).parent.mkdir(parents=True, exist_ok=True)
                Path(args.dump).write_text(json.dumps(state, indent=2, default=str))
            if args.shot:
                Path(args.shot).parent.mkdir(parents=True, exist_ok=True)
                compose(args.background).save(args.shot)
            if args.panel_shot:
                # The dropdown draws inside a transparent full-screen window,
                # the tallest one: keep only its opaque part.
                window = max((w for w in QGuiApplication.topLevelWindows() if w.isVisible()),
                             key=lambda w: w.height())
                grab = window.grabWindow()
                box = QRegion(QBitmap.fromImage(grab.createAlphaMask())).boundingRect()
                grab.copy(box).save(args.panel_shot)
        except Exception as error:  # a broken capture must not hang the run
            import traceback

            traceback.print_exc()
            print(f"capture failed: {error}", file=sys.stderr)
            status["code"] = 5
        finally:
            app.quit()

    steps = [step.strip() for step in args.do.split(",") if step.strip()]
    recorded: list[str] = []

    def run_next():
        if not steps:
            QTimer.singleShot(args.step_delay, capture)
            return
        step = steps.pop(0)
        plugin = harness.property("plugin")
        store = harness.property("store")
        if plugin is None or store is None:
            print("plugin not ready for interactions", file=sys.stderr)
            status["code"] = 3
            app.quit()
            return
        delay = (
            int(step.partition(":")[2]) if step.startswith("wait:") else args.step_delay
        )
        apply_step(step, plugin, store, harness)

        def record(index=len(recorded), label=step):
            if not args.dump_each:
                return
            directory = Path(args.dump_each)
            directory.mkdir(parents=True, exist_ok=True)
            safe = label.replace("/", "_").replace(":", "-")
            state = snapshot(plugin, store)
            (directory / f"{index:02d}-{safe}.json").write_text(
                json.dumps(state, indent=2, default=str)
            )

        recorded.append(step)

        def finish_step():
            # One timer for both, so a step's dump can never land after the
            # next step has started; Qt's coarse timers may fire 5% early or late.
            record()
            run_next()

        QTimer.singleShot(delay, finish_step)

    if args.open_panel:
        QTimer.singleShot(args.settle, harness.openPanel)
        QTimer.singleShot(args.settle + 400, run_next)
    else:
        QTimer.singleShot(args.settle, run_next)

    app.exec()
    return status["code"]


if __name__ == "__main__":
    raise SystemExit(main())
