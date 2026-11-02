"""Stand-ins for the `Quickshell.Io` QML module: process execution and file reads."""

import os

from PySide6.QtCore import Property, QObject, QProcess, QTimer, Signal, Slot
from PySide6.QtNetwork import QLocalSocket
from PySide6.QtQml import QmlElement

from .qmlprops import declare

QML_IMPORT_NAME = "Quickshell.Io"
QML_IMPORT_MAJOR_VERSION = 1


@QmlElement
class StdioCollector(QObject):
    """Buffers a whole stream and hands it over once the process exits."""

    textChanged = Signal()
    streamFinished = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._text = ""
        self._wait_for_end = False

    def _get_text(self):
        return self._text

    def _set_text(self, value):
        if self._text != value:
            self._text = value
            self.textChanged.emit()

    text = Property(str, _get_text, _set_text, notify=textChanged)

    def _get_wait(self):
        return self._wait_for_end

    def _set_wait(self, value):
        self._wait_for_end = value

    waitForEnd = Property(bool, _get_wait, _set_wait)

    def reset(self):
        self._set_text("")

    def feed(self, chunk):
        self._set_text(self._text + chunk)

    def finish(self):
        self.streamFinished.emit()


@QmlElement
class SplitParser(QObject):
    """Emits `read` once per delimited chunk, like the real incremental parser."""

    read = Signal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._split_marker = "\n"
        self._buffer = ""

    def _get_marker(self):
        return self._split_marker

    def _set_marker(self, value):
        self._split_marker = value

    splitMarker = Property(str, _get_marker, _set_marker)

    def reset(self):
        self._buffer = ""

    def feed(self, chunk):
        if self._split_marker == "":
            # Unsplit: every chunk as it arrives, as Quickshell does.
            self.read.emit(chunk)
            return
        self._buffer += chunk
        marker = self._split_marker
        while marker in self._buffer:
            head, self._buffer = self._buffer.split(marker, 1)
            self.read.emit(head)

    def finish(self):
        if self._buffer:
            tail, self._buffer = self._buffer, ""
            self.read.emit(tail)


# Commands that read their input on stdin, recorded with that input instead of
# run; tests assert on these.
PIPED_COMMANDS = {"wl-copy"}
# Recorded the same way and finished at once: tests must not play sounds.
SILENT_COMMANDS = {"pw-play"}
PIPED = []


@QmlElement
class Process(QObject):
    commandChanged = Signal()
    runningChanged = Signal()
    exited = Signal(int, int)
    started = Signal()
    stdinEnabledChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._command = []
        self._running = False
        self._stdout = None
        self._stderr = None
        self._working_directory = ""
        self._proc = None
        self._stdin_enabled = False
        self._piped = None

    def _get_command(self):
        return self._command

    def _set_command(self, value):
        self._command = [str(part) for part in (value or [])]
        self.commandChanged.emit()

    command = Property("QVariantList", _get_command, _set_command, notify=commandChanged)

    def _get_stdout(self):
        return self._stdout

    def _set_stdout(self, value):
        self._stdout = value

    stdout = Property(QObject, _get_stdout, _set_stdout)

    def _get_stderr(self):
        return self._stderr

    def _set_stderr(self, value):
        self._stderr = value

    stderr = Property(QObject, _get_stderr, _set_stderr)

    def _get_wd(self):
        return self._working_directory

    def _set_wd(self, value):
        self._working_directory = value

    workingDirectory = Property(str, _get_wd, _set_wd)

    # Extra environment variables for the child (Omarchy 4.5 sets some).
    def _get_env(self):
        return getattr(self, "_environment", {})

    def _set_env(self, value):
        from PySide6.QtQml import QJSValue
        if isinstance(value, QJSValue):
            value = value.toVariant()
        self._environment = dict(value or {})

    environment = Property("QVariantMap", _get_env, _set_env)

    def _get_running(self):
        return self._running

    def _set_running(self, value):
        if value and not self._running:
            self._start()
        elif not value and self._running:
            self._stop()

    running = Property(bool, _get_running, _set_running, notify=runningChanged)

    def _get_stdin_enabled(self):
        return self._stdin_enabled

    def _set_stdin_enabled(self, value):
        value = bool(value)
        if value == self._stdin_enabled:
            return
        self._stdin_enabled = value
        self.stdinEnabledChanged.emit()
        if not value and self._running:
            if self._piped is not None:
                # Closing stdin is the end of a piped command's input.
                self._finalize(0, 0)
            elif self._proc is not None:
                self._proc.closeWriteChannel()

    stdinEnabled = Property(bool, _get_stdin_enabled, _set_stdin_enabled, notify=stdinEnabledChanged)

    @Slot(str)
    def write(self, data):
        if not self._running or not self._stdin_enabled:
            return
        if self._piped is not None:
            self._piped["stdin"] += data
        elif self._proc is not None:
            self._proc.write(data.encode("utf-8"))

    def _start(self):
        if not self._command:
            return
        self._running = True
        self.runningChanged.emit()
        if os.path.basename(self._command[0]) in PIPED_COMMANDS | SILENT_COMMANDS:
            # Recorded, never run: tests must not raise real notifications or
            # write the developer's clipboard.
            self._piped = {"command": list(self._command), "stdin": ""}
            PIPED.append(self._piped)
            self.started.emit()
            if os.path.basename(self._command[0]) in SILENT_COMMANDS:
                QTimer.singleShot(0, lambda: self._finalize(0, 0))
            return
        # Each run starts from an empty buffer, as the real collector does.
        for stream in (self._stdout, self._stderr):
            if stream is not None:
                stream.reset()
        self._proc = QProcess(self)
        self._proc.setProgram(self._command[0])
        self._proc.setArguments(self._command[1:])
        if self._working_directory:
            self._proc.setWorkingDirectory(self._working_directory)
        if getattr(self, "_environment", None):
            from PySide6.QtCore import QProcessEnvironment
            env = QProcessEnvironment.systemEnvironment()
            for key, value in self._environment.items():
                if value is None:
                    env.remove(str(key))
                else:
                    env.insert(str(key), str(value))
            self._proc.setProcessEnvironment(env)
        self._proc.readyReadStandardOutput.connect(self._drain_stdout)
        self._proc.readyReadStandardError.connect(self._drain_stderr)
        self._proc.finished.connect(self._on_finished)
        self._proc.errorOccurred.connect(self._on_error)
        self._proc.start()
        self.started.emit()

    def _stop(self):
        if self._proc is not None:
            self._proc.kill()

    def _decode(self, data):
        return bytes(data).decode("utf-8", "replace")

    def _drain_stdout(self):
        # A read can still arrive after finalize cleared the process.
        if self._proc is None:
            return
        chunk = self._decode(self._proc.readAllStandardOutput())
        if chunk and self._stdout is not None:
            self._stdout.feed(chunk)

    def _drain_stderr(self):
        if self._proc is None:
            return
        chunk = self._decode(self._proc.readAllStandardError())
        if chunk and self._stderr is not None:
            self._stderr.feed(chunk)

    def _on_error(self, error):
        if error == QProcess.FailedToStart:
            self._finalize(127, 1)

    def _on_finished(self, exit_code, exit_status):
        self._drain_stdout()
        self._drain_stderr()
        self._finalize(exit_code, 0 if exit_status == QProcess.NormalExit else 1)

    def _finalize(self, exit_code, exit_status):
        if not self._running:
            return
        self._running = False
        for stream in (self._stdout, self._stderr):
            if stream is not None:
                stream.finish()
        self._proc = None
        self._piped = None
        self.runningChanged.emit()
        self.exited.emit(exit_code, exit_status)


@QmlElement
class FileView(QObject):
    loaded = Signal()
    loadFailed = Signal(int)
    fileChanged = Signal()
    pathChanged = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._path = ""
        self._watch_changes = False
        self._print_errors = True
        self._block = False
        self._text = ""

    def _get_path(self):
        return self._path

    def _set_path(self, value):
        self._path = value
        self.pathChanged.emit()
        self.reload()

    path = Property(str, _get_path, _set_path, notify=pathChanged)

    def _flag(attr, default):
        def getter(self):
            return getattr(self, attr, default)

        def setter(self, value):
            setattr(self, attr, value)

        return Property(bool, getter, setter)

    watchChanges = _flag("_watch_changes", False)
    printErrors = _flag("_print_errors", True)
    blockLoadingUntilLoaded = _flag("_block", False)
    blockLoading = _flag("_block_loading", False)   # Quickshell's name for it (Omarchy 4.5 sets it)
    del _flag

    @Slot(result=str)
    def text(self):
        return self._text

    @Slot()
    def reload(self):
        try:
            with open(os.path.expanduser(self._path), "r", encoding="utf-8") as handle:
                self._text = handle.read()
        except OSError:
            self._text = ""
            self.loadFailed.emit(2)
            return
        self.loaded.emit()


@QmlElement
class IpcHandler(QObject):
    """Accepts the declaration so panels load; the harness calls methods directly.
    Its properties notify, so bindings over them (Omarchy 4.5's IpcRegistry) are fine."""

    changed = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._target = ""
        self._enabled = True

    target = declare(str, "_target", changed, "")
    enabled = declare(bool, "_enabled", changed, True)


@QmlElement
class Socket(QObject):
    """Quickshell's Socket: a local (Unix) socket that writes text and feeds a
    parser. Setting `connected` connects or disconnects."""

    connectedChanged = Signal()
    pathChanged = Signal()
    error = Signal(int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._path = ""
        self._parser = None
        self._socket = QLocalSocket(self)
        # Lambdas, not bound methods: PySide holds bound-method slots weakly, so
        # a socket QML creates at run time would lose them when its Python
        # wrapper is collected. The lambdas keep it alive as long as the socket.
        self._socket.connected.connect(lambda: self.connectedChanged.emit())
        self._socket.disconnected.connect(lambda: self._on_disconnected())
        self._socket.readyRead.connect(lambda: self._on_ready_read())
        self._socket.errorOccurred.connect(lambda e: self.error.emit(int(e.value) if hasattr(e, "value") else int(e)))

    def _get_path(self):
        return self._path

    def _set_path(self, value):
        if value != self._path:
            self._path = value
            self.pathChanged.emit()

    path = Property(str, _get_path, _set_path, notify=pathChanged)

    def _get_parser(self):
        return self._parser

    def _set_parser(self, value):
        self._parser = value

    parser = Property(QObject, _get_parser, _set_parser)

    def _get_connected(self):
        return self._socket.state() == QLocalSocket.LocalSocketState.ConnectedState

    def _set_connected(self, value):
        if value:
            self._socket.connectToServer(self._path)
        else:
            self._socket.disconnectFromServer()

    connected = Property(bool, _get_connected, _set_connected, notify=connectedChanged)

    def _on_ready_read(self):
        data = bytes(self._socket.readAll().data()).decode("utf-8", "replace")
        if self._parser is not None:
            self._parser.feed(data)

    def _on_disconnected(self):
        self._on_ready_read()
        if self._parser is not None:
            self._parser.finish()
        self.connectedChanged.emit()

    @Slot(str)
    def write(self, data):
        self._socket.write(data.encode("utf-8"))

    @Slot()
    def flush(self):
        self._socket.flush()
