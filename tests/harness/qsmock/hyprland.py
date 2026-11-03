"""Stand-ins for `Quickshell.Hyprland`: what Omarchy 4.5's Commons/Ui touch
(the Hyprland singleton's monitors and HyprlandFocusGrab). Inert: there is no
compositor in the harness."""

from PySide6.QtCore import Property, QObject, Signal, Slot
from PySide6.QtQml import QmlElement, QmlSingleton

from .qmlprops import declare

QML_IMPORT_NAME = "Quickshell.Hyprland"
QML_IMPORT_MAJOR_VERSION = 1


class _Monitors(QObject):
    changed = Signal()

    @Property("QVariantList", notify=changed)
    def values(self):
        return []


@QmlElement
@QmlSingleton
class Hyprland(QObject):
    changed = Signal()
    rawEvent = Signal("QVariant")

    def __init__(self, parent=None):
        super().__init__(parent)
        self._monitors = _Monitors(self)

    @Property(QObject, notify=changed)
    def monitors(self):
        return self._monitors

    @Property(QObject, notify=changed)
    def focusedMonitor(self):
        return None

    @Slot()
    def refreshMonitors(self):
        pass

    @Slot(str)
    def dispatch(self, request):
        pass


@QmlElement
class HyprlandFocusGrab(QObject):
    changed = Signal()
    cleared = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._active = False
        self._windows = []

    active = declare(bool, "_active", changed, False)
    windows = declare("QVariantList", "_windows", changed, [])
