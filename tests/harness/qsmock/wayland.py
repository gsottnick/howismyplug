"""Stand-ins for `Quickshell.Wayland`: layer-shell hints, accepted and ignored."""

from PySide6.QtCore import Property, QObject, Signal
from PySide6.QtQml import QmlAnonymous, QmlAttached, QmlElement, QmlSingleton

from .qmlprops import declare

QML_IMPORT_NAME = "Quickshell.Wayland"
QML_IMPORT_MAJOR_VERSION = 1


@QmlAnonymous
class WlrLayershellAttached(QObject):
    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._namespace = ""
        self._layer = 0
        self._keyboardFocus = 0
        self._exclusiveZone = 0

    namespace = declare(str, "_namespace", changed, "")
    layer = declare(int, "_layer", changed, 0)
    keyboardFocus = declare(int, "_keyboardFocus", changed, 0)
    exclusiveZone = declare(int, "_exclusiveZone", changed, 0)


@QmlElement
@QmlAttached(WlrLayershellAttached)
class WlrLayershell(QObject):
    @staticmethod
    def qmlAttachedProperties(*args):
        # PySide passes the attaching type alongside the target object.
        return WlrLayershellAttached(args[-1])


@QmlElement
@QmlSingleton
class WlrLayer(QObject):
    Background = Property(int, lambda self: 0, constant=True)
    Bottom = Property(int, lambda self: 1, constant=True)
    Top = Property(int, lambda self: 2, constant=True)
    Overlay = Property(int, lambda self: 3, constant=True)


# `None` is a keyword, so this enum cannot be written as a class body.
WlrKeyboardFocus = QmlSingleton(
    QmlElement(
        type(
            "WlrKeyboardFocus",
            (QObject,),
            {
                "None": Property(int, lambda self: 0, constant=True),
                "OnDemand": Property(int, lambda self: 1, constant=True),
                "Exclusive": Property(int, lambda self: 2, constant=True),
            },
        )
    )
)
