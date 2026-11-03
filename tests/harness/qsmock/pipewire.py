"""Stand-ins for `Quickshell.Services.Pipewire`: Omarchy 4.5's Commons read the
default audio devices. There is no audio server in the harness: none."""

from PySide6.QtCore import Property, QObject, Signal
from PySide6.QtQml import QmlElement, QmlSingleton

from .qmlprops import declare

QML_IMPORT_NAME = "Quickshell.Services.Pipewire"
QML_IMPORT_MAJOR_VERSION = 1


@QmlElement
@QmlSingleton
class Pipewire(QObject):
    changed = Signal()

    @Property(QObject, notify=changed)
    def defaultAudioSource(self):
        return None

    @Property(QObject, notify=changed)
    def defaultAudioSink(self):
        return None

    @Property("QVariantList", notify=changed)
    def nodes(self):
        return []


@QmlElement
class PwObjectTracker(QObject):
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._objects = []

    objects = declare("QVariantList", "_objects", changed, [])
