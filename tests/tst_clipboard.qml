import QtQuick
import QtQuick.Controls as Controls
import QtTest
import Quickshell.Io
import "../components" as Plugin

Item {
    id: root

    property bool ready: false

    height: 250
    width: 500

    Timer {
        interval: 100
        running: true

        onTriggered: root.ready = true
    }
    Plugin.SafeTextField {
        id: field

        height: 36
        placeholderText: "Folder path"
        width: 200
    }
    Controls.Button {
        id: nextButton

        text: "Next"
        y: 50
    }
    SignalSpy {
        id: edits

        signalName: "textEdited"
        target: field
    }
    SignalSpy {
        id: accepts

        signalName: "accepted"
        target: field
    }
    SignalSpy {
        id: finishes
        signalName: "editingFinished"
        target: field
    }
    Process {
        id: setup

        property bool done: false

        onExited: done = true
    }
    TestCase {
        function cleanup() {
            if (qtest_results.failed)
                console.error("CLIPBOARD_FAILED " + qtest_results.functionName + " text=" + JSON.stringify(field.text) + " error=" + field.pasteError + " selection=" + field.selectionStart + ":" + field.selectionEnd + " scroll=" + field.contentX + " focus=" + field.inputActiveFocus);
            field.cancelPaste();
        }
        function init() {
            field.visible = true;
            field.enabled = true;
            field.text = "";
            field.pasteError = "";
            field.focusInput();
            tryCompare(field, "inputActiveFocus", true);
            source("normal");
            edits.clear();
            accepts.clear();
            finishes.clear();
        }
        function paste(key, modifiers) {
            keyClick(key, modifiers);
            tryCompare(field, "pasteRunning", false, 4000);
        }
        function source(mode) {
            setup.command = ["clipboard-fixture", mode];
            setup.done = false;
            setup.running = true;
            tryCompare(setup, "done", true);
        }
        function test_close_and_disable_cancel_paste() {
            source("delayed");
            keyClick(Qt.Key_V, Qt.ControlModifier);
            field.visible = false;
            tryCompare(field, "pasteRunning", false);
            field.visible = true;
            field.focusInput();
            wait(500);
            compare(field.text, "");
            keyClick(Qt.Key_V, Qt.ControlModifier);
            field.enabled = false;
            tryCompare(field, "pasteRunning", false);
            field.enabled = true;
            wait(500);
            compare(field.text, "");
        }
        function test_context_menu_paste() {
            var menu = findChild(field, "clipboardMenu");
            verify(menu !== null);
            menu.popup();
            tryCompare(menu, "opened", true);
            menu.itemAt(5).triggered();
            tryCompare(field, "pasteRunning", false);
            compare(field.text, "folder");
            compare(menu.opened, false);
        }
        function test_keyboard_unicode_selection_undo_redo() {
            field.text = "before-old-after";
            field.select(7, 10);
            source("unicode");
            paste(Qt.Key_V, Qt.ControlModifier);
            compare(field.text, "before-/home/test/Blåbær 📁-after");
            compare(edits.count, 1);
            field.undo();
            compare(field.text, "before-old-after");
            field.redo();
            compare(field.text, "before-/home/test/Blåbær 📁-after");
        }
        function test_late_result_does_not_follow_navigation() {
            field.text = "keep";
            field.cursorPosition = 4;
            source("delayed");
            keyClick(Qt.Key_V, Qt.ControlModifier);
            keyClick(Qt.Key_Left);
            tryCompare(field, "pasteRunning", false);
            compare(field.text, "keep");
        }
        function test_late_result_does_not_overwrite_typing() {
            source("delayed");
            keyClick(Qt.Key_V, Qt.ControlModifier);
            verify(field.pasteRunning);
            keyClick(Qt.Key_X);
            tryCompare(field, "pasteRunning", false);
            compare(field.text, "x");
        }
        function test_numeric_padding_does_not_clip() {
            field.height = 34;
            field.leftPadding = 7;
            field.rightPadding = 7;
            field.font.pixelSize = 12;
            field.text = "3600";
            wait(50);
            var editor = findChild(field, "safeEditor");
            verify(editor !== null);
            compare(editor.topPadding, 0);
            compare(editor.bottomPadding, 0);
            compare(editor.leftPadding, 7);
            compare(editor.rightPadding, 7);
            verify(editor.cursorRectangle.y + editor.cursorRectangle.height + editor.topPadding <= field.height);
            field.height = 36;
        }
        function test_long_path_scrolls() {
            source("long");
            paste(Qt.Key_V, Qt.ControlModifier);
            compare(field.text.length, 400);
            verify(field.contentX > 0);
            keyClick(Qt.Key_Home);
            tryCompare(field, "contentX", 0);
        }
        function test_middle_click_primary() {
            mouseClick(field, 15, 15, Qt.MiddleButton);
            tryCompare(field, "pasteRunning", false);
            compare(field.text, "folder");
        }
        function test_paste_keeps_field_length_limit() {
            source("limit");
            paste(Qt.Key_V, Qt.ControlModifier);
            paste(Qt.Key_V, Qt.ControlModifier);
            compare(field.text.length, 32767);
            paste(Qt.Key_V, Qt.ControlModifier);
            compare(field.text.length, 32767);
            field.undo();
            compare(field.text.length, 16384);
        }
        function test_rejected_source_leaves_selection_unchanged(data) {
            field.text = "keep";
            field.selectAll();
            source(data.mode);
            paste(Qt.Key_V, Qt.ControlModifier);
            compare(field.text, "keep");
            compare(field.selectionStart, 0);
            compare(field.selectionEnd, 4);
            verify(field.pasteError !== "");
        }
        function test_rejected_source_leaves_selection_unchanged_data() {
            return [
                {
                    tag: "large",
                    mode: "large"
                },
                {
                    tag: "stream",
                    mode: "stream"
                },
                {
                    tag: "failure",
                    mode: "failure"
                },
                {
                    tag: "stall",
                    mode: "stall"
                }
            ];
        }
        function test_repeated_paste_and_duplicate_shortcut() {
            source("delayed");
            keyClick(Qt.Key_V, Qt.ControlModifier);
            keyClick(Qt.Key_V, Qt.ControlModifier);
            tryCompare(field, "pasteRunning", false);
            compare(field.text, "later");
            source("normal");
            paste(Qt.Key_V, Qt.ControlModifier);
            compare(field.text, "laterfolder");
            field.undo();
            compare(field.text, "later");
        }
        function test_shift_insert_empty_and_plain_text() {
            source("empty");
            field.text = "keep";
            field.selectAll();
            paste(Qt.Key_Insert, Qt.ShiftModifier);
            compare(field.text, "");
            field.text = "keep";
            field.selectAll();
            source("normal");
            paste(Qt.Key_Insert, Qt.ShiftModifier);
            compare(field.text, "folder");
        }
        function test_typing_after_paste_has_separate_undo() {
            paste(Qt.Key_V, Qt.ControlModifier);
            keyClick(Qt.Key_X);
            compare(field.text, "folderx");
            field.undo();
            compare(field.text, "folder");
            field.undo();
            compare(field.text, "");
        }
        function test_typing_navigation_and_tab() {
            keyClick(Qt.Key_A);
            keyClick(Qt.Key_B);
            keyClick(Qt.Key_C);
            compare(field.text, "abc");
            keyClick(Qt.Key_Left);
            keyClick(Qt.Key_Backspace);
            compare(field.text, "ac");
            keyClick(Qt.Key_Tab);
            tryCompare(nextButton, "activeFocus", true);
            compare(finishes.count, 1);
            keyClick(Qt.Key_Backtab);
            tryCompare(field, "inputActiveFocus", true);
            keyClick(Qt.Key_Return);
            compare(field.text, "ac");
            compare(accepts.count, 1);
            compare(finishes.count, 2);
        }

        name: "SafeClipboard"
        when: root.ready

        onCompletedChanged: if (completed) {
            console.log("CLIPBOARD_RESULT passed=" + qtest_results.passCount + " failed=" + qtest_results.failCount);
            Qt.quit();
        }
    }
}
