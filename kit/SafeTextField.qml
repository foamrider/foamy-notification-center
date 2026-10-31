// foamy-kit 0.4.0 c741d6fcac65bfb155c54c3933addc244163c74642ceae4a28b68cec16367abf — do not edit; change foamy-kit and run sync
import QtQuick
import QtQuick.Controls as Controls
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// A single-line text field that never lets Qt read the clipboard itself.
//
// Qt's TextField reads the whole clipboard on every change, so a huge or
// hostile clipboard can stall the shell. Paste (Ctrl+V, the context menu,
// middle-click) runs clipboard.sh instead: bounded to 16 KiB, NUL-free, one
// line, 2 s deadline, and late results never overwrite newer typing.
//
//   SafeTextField {
//     width: parent.width
//     text: root.query
//     placeholderText: FoamyI18n.t("Search")
//     translate: FoamyI18n.t                 // context menu labels
//     onTextEdited: root.query = text
//     onAccepted: root.search()
//     onKeyPressed: function(event) { if (event.key === Qt.Key_Down) { list.focus(); event.accepted = true } }
//   }
//
// Styled once (foamy radius, control fill and border); callers set size and
// alignment, never background. clipboardScript resolves relative to this
// file (kit/clipboard.sh by default) unless absolute.

Flickable {
    id: root

    // Match the stock UI kit while keeping native clipboard reads out of the editor.
    property color foreground: Commons.Color.foreground
    property color accent: Commons.Color.accent
    property string clipboardScript: "clipboard.sh"
    // Longest text the field keeps (typing and paste), like TextField.maximumLength.
    property int maximumLength: 32767
    property real cornerRadius: FoamyStyle.radius
    property color selectionTint: Style.selectionFillFor(foreground, accent)
    property bool hasCursor: false
    readonly property bool _focused: editor.activeFocus
    readonly property bool _hot: editor.hovered || hasCursor
    readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), foreground, accent)
    property alias background: editor.background
    property bool editorReady: false
    property alias color: editor.color
    property alias cursorPosition: editor.cursorPosition
    property alias font: editor.font
    property alias horizontalAlignment: editor.horizontalAlignment
    readonly property bool inputActiveFocus: editor.activeFocus
    // The editor itself (tests, glyph geometry).
    readonly property Item editorItem: editor
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
            // Keep maximumLength (TextInput's 32767 by default), including repeated pastes.
            value = value.slice(0, Math.max(0, root.maximumLength - editor.length + pasteEnd - pasteStart));
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
        clipboard.command = ["bash", decodeURIComponent(Qt.resolvedUrl(clipboardScript).toString().replace(/^file:\/\//, "")), primary ? "primary" : "clipboard"];
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
    implicitHeight: FoamyStyle.controlHeight
    // Explicit, so it follows LayoutMirroring: right-aligned in RTL panels
    // (an implicit alignment only follows the text's own direction).
    horizontalAlignment: TextEdit.AlignLeft
    font.family: FoamyStyle.fontFamily
    font.pixelSize: FoamyStyle.font.body
    color: foreground
    selectionColor: selectionTint
    selectedTextColor: foreground
    placeholderTextColor: Qt.darker(foreground, 1.6)
    leftPadding: Style.spacing.controlPaddingX + Border.left(_borderSpec)
    rightPadding: Style.spacing.controlPaddingX + Border.right(_borderSpec)
    background: BorderSurface {
        color: Style.controlFill(root._focused, root._hot, root.foreground, root.accent)
        borderSpec: root._borderSpec
        radius: root.cornerRadius
    }

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
            var wanted = root.maximumLength;
            var limit = wanted > 32767 ? 32767 : (wanted > 0 ? wanted : 0);
            if (length > limit)
                remove(limit, length);
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

    // Keep the horizontal scroll inside the text. The attached TextArea
    // resizes contentWidth to the text's own width (overriding the binding
    // above), and a field given an explicit `width:` (a Column child) then
    // ended up scrolled to contentX = -leftPadding: the text sat one padding
    // too far in. Clamp whenever the geometry or the scroll changes.
    function clampScroll() {
        if (!editorReady)
            return;
        var max = contentWidth > width ? contentWidth - width : 0;
        if (contentX < 0)
            contentX = 0;
        else if (contentX > max)
            contentX = max;
    }
    onWidthChanged: clampScroll()
    onContentWidthChanged: clampScroll()
    onContentXChanged: clampScroll()
    Component.onCompleted: {
        editorReady = true;
        clampScroll();
    }
    // Runs when maximumLength changes after creation only, and uses no JS
    // globals: this can fire while a page is being built or torn down (a
    // settings state switch), when the global object may already be gone.
    onMaximumLengthChanged: {
        if (!editorReady)
            return;
        var limit = maximumLength > 0 ? maximumLength : 0;
        if (editor.length > limit)
            editor.remove(limit, editor.length);
    }
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
