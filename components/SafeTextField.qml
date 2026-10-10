import QtQuick
import QtQuick.Controls as Controls
import Quickshell.Io

Flickable {
    id: root

    property alias background: editor.background
    property bool editorReady: false
    property alias color: editor.color
    property alias cursorPosition: editor.cursorPosition
    property alias font: editor.font
    readonly property bool inputActiveFocus: editor.activeFocus
    property alias padding: editor.padding
    property alias leftPadding: editor.leftPadding
    property int pasteCursor: 0
    property int pasteEnd: 0
    property string pasteError: ""
    property int pasteRevision: -1
    readonly property bool pasteRunning: pasteRevision >= 0 || clipboard.running
    property int pasteStart: 0
    property alias placeholderText: editor.placeholderText
    property alias placeholderTextColor: editor.placeholderTextColor
    property int revision: 0
    property alias rightPadding: editor.rightPadding
    property alias selectedTextColor: editor.selectedTextColor
    property alias selectionColor: editor.selectionColor
    property alias selectionEnd: editor.selectionEnd
    property alias selectionStart: editor.selectionStart
    property alias text: editor.text
    property var translate: function (key) {
        return key;
    }

    signal keyPressed(var event)
    signal editingFinished
    signal accepted
    signal textEdited

    function cancelPaste() {
        pasteRevision = -1;
        clipboard.running = false;
    }
    function cut() {
        var before = editor.text;
        editor.cut();
        if (editor.text !== before)
            root.textEdited();
    }

    // Late clipboard results must not overwrite typing, navigation, or a closed form.
    function finishPaste(code, output) {
        var current = enabled && visible && editor.activeFocus && pasteRevision === revision && pasteStart === editor.selectionStart && pasteEnd === editor.selectionEnd && pasteCursor === editor.cursorPosition;
        pasteRevision = -1;
        if (!current)
            return;
        if (code !== 0) {
            pasteError = code === 124 || code === 137 ? "Clipboard paste timed out. Copy the text again." : code === 5 ? "Clipboard text is too large or contains invalid characters." : "Could not paste clipboard text. Copy plain text and try again.";
            return;
        }
        try {
            var value = JSON.parse(output);
            if (typeof value !== "string" || value.length > 16384)
                throw new Error("Invalid clipboard result");
            if (value === "" && pasteStart === pasteEnd)
                return;
            // Preserve TextInput's default length limit, including repeated pastes.
            value = value.slice(0, Math.max(0, 32767 - editor.length + pasteEnd - pasteStart));
            if (value === "" && pasteStart === pasteEnd)
                return;
            // These fields are not file-backed. Reset the document's modified
            // marker at each boundary to prevent Qt from merging adjacent typing
            // or pastes, while retaining its native undo stack.
            editor.textDocument.modified = false;
            editor.cursorSelection.text = value;
            editor.cursorPosition = pasteStart + value.length;
            editor.textDocument.modified = false;
            root.textEdited();
        } catch (error) {
            pasteError = "Could not paste clipboard text. Copy plain text and try again.";
        }
    }
    function focusInput() {
        editor.forceActiveFocus();
    }
    function redo() {
        // Programmatic TextEdit actions do not emit textEdited; menu edits must.
        var before = editor.text;
        editor.redo();
        if (editor.text !== before)
            root.textEdited();
    }
    function requestPaste(primary) {
        if (!enabled || !visible || pasteRunning)
            return;
        pasteError = "";
        pasteRevision = revision;
        pasteStart = editor.selectionStart;
        pasteEnd = editor.selectionEnd;
        pasteCursor = editor.cursorPosition;
        clipboard.command = ["bash", decodeURIComponent(Qt.resolvedUrl("clipboard.sh").toString().replace(/^file:\/\//, "")), primary ? "primary" : "clipboard"];
        clipboard.running = true;
    }
    function select(start, end) {
        editor.select(start, end);
    }
    function selectAll() {
        editor.selectAll();
    }
    function undo() {
        var before = editor.text;
        editor.undo();
        if (editor.text !== before)
            root.textEdited();
    }

    // Expose the native editable control, with the caller's field label.
    Accessible.ignored: true
    boundsBehavior: Flickable.StopAtBounds
    clip: true
    contentHeight: height
    contentWidth: Math.max(width, editor.contentWidth + editor.leftPadding + editor.rightPadding)
    flickableDirection: Flickable.HorizontalFlick
    implicitHeight: 36

    // TextArea checks clipboard formats only. TextField reads the entire clipboard
    // even on dataChanged, so intercepting its paste shortcut is not sufficient.
    Controls.TextArea.flickable: Controls.TextArea {
        id: editor
        objectName: "safeEditor"

        Accessible.name: root.Accessible.name
        activeFocusOnTab: true
        persistentSelection: true
        selectByMouse: true
        textFormat: TextEdit.PlainText
        // Attached TextArea margins otherwise shift centered single-line glyphs.
        topPadding: 0
        bottomPadding: 0
        verticalAlignment: TextEdit.AlignVCenter
        wrapMode: TextEdit.NoWrap

        // Use our own menu so no menu action calls native paste or reads canPaste.
        Controls.ContextMenu.menu: Controls.Menu {
            id: editMenu

            objectName: "clipboardMenu"

            Controls.MenuItem {
                enabled: editor.canUndo
                text: root.translate("Undo")

                onTriggered: root.undo()
            }
            Controls.MenuItem {
                enabled: editor.canRedo
                text: root.translate("Redo")

                onTriggered: root.redo()
            }
            Controls.MenuSeparator {}
            Controls.MenuItem {
                enabled: editor.selectedText !== ""
                text: root.translate("Cut")

                onTriggered: root.cut()
            }
            Controls.MenuItem {
                enabled: editor.selectedText !== ""
                text: root.translate("Copy")

                onTriggered: editor.copy()
            }
            Controls.MenuItem {
                enabled: !root.pasteRunning
                text: root.translate("Paste")

                onTriggered: {
                    editMenu.close();
                    root.focusInput();
                    root.requestPaste(false);
                }
            }
            Controls.MenuItem {
                text: root.translate("Select all")

                onTriggered: editor.selectAll()
            }
        }

        Keys.onPressed: function (event) {
            // Callers retain search navigation and Escape without native paste.
            event.accepted = false;
            root.keyPressed(event);
            if (event.accepted)
                return;
            if (event.matches(StandardKey.Paste)) {
                event.accepted = true;
                root.requestPaste(false);
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                event.accepted = true;
                root.accepted();
                root.editingFinished();
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                event.accepted = true;
                var backwards = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier);
                nextItemInFocusChain(!backwards).forceActiveFocus(Qt.TabFocusReason);
            }
        }
        onActiveFocusChanged: if (!activeFocus) {
            root.cancelPaste();
            root.editingFinished();
        }
        onCursorRectangleChanged: {
            // Initial layout can fire before the QML JavaScript context is ready.
            if (!root.editorReady)
                return;
            var left = cursorRectangle.x;
            var right = left + cursorRectangle.width + rightPadding;
            if (left < root.contentX)
                root.contentX = Math.max(0, left);
            else if (right > root.contentX + root.width)
                root.contentX = Math.min(root.contentWidth - root.width, right - root.width);
        }
        onTextChanged: {
            if (length > 32767)
                remove(32767, length);
            root.revision++;
            root.pasteError = "";
        }
        onTextEdited: root.textEdited()

        // Keep left-button selection native; consume primary-selection paste.
        MouseArea {
            acceptedButtons: Qt.MiddleButton
            anchors.fill: parent

            onClicked: root.requestPaste(true)
            onPressed: function (mouse) {
                editor.forceActiveFocus();
                editor.cursorPosition = editor.positionAt(mouse.x, mouse.y);
            }
        }
    }

    Component.onCompleted: editorReady = true
    Component.onDestruction: cancelPaste()
    onActiveFocusChanged: if (activeFocus)
        editor.forceActiveFocus()
    onEnabledChanged: if (!enabled)
        cancelPaste()
    onVisibleChanged: if (!visible) {
        cancelPaste();
        pasteError = "";
    }

    Process {
        id: clipboard

        stdout: StdioCollector {
            id: clipboardOutput
        }

        onExited: function (code) {
            root.finishPaste(code, clipboardOutput.text);
        }
        onRunningChanged: if (!running && root.pasteRevision >= 0)
            root.finishPaste(-1, "")
    }
}
