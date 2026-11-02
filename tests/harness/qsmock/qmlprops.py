"""Small helper for declaring notifying QML properties on the mocks."""

from PySide6.QtCore import Property


def declare(type_, attr, signal, default=None):
    """A read/write Property backed by `attr`, emitting `signal` on change.

    Written as a module-level factory because a class body is not a closure:
    a helper defined inside the class cannot see the signal declared beside it.
    """

    def getter(self):
        return getattr(self, attr, default)

    def setter(self, value):
        if getattr(self, attr, default) != value:
            setattr(self, attr, value)
            signal.__get__(self, type(self)).emit()

    return Property(type_, getter, setter, notify=signal)


def plain(type_, attr, default=None):
    """A read/write Property with no change notification."""

    def getter(self):
        return getattr(self, attr, default)

    def setter(self, value):
        setattr(self, attr, value)

    return Property(type_, getter, setter)
