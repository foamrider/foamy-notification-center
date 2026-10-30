"""Offscreen test host: load the host's shell QML (and data) only, never its scripts.

OMARCHY_TEST_ROOT (or OMARCHY_SHELL_PATH's parent) selects the host tree, e.g. the
installed 4.0.6 /usr/share/omarchy or an extracted 4.5 tree under /tmp/omarchy-ref.
Only `shell/` and `default/` are exposed through a private OMARCHY_PATH; its `bin/`
and every `omarchy-*` on PATH are logging stubs. `omarchy-shell` reaches this test's
own shell only (qs ipc -p APP), never the live session. check() asserts nothing
under /tmp/omarchy-ref (or the installed bin) was executed.
"""
import os
from pathlib import Path

REF = '/tmp/omarchy-ref'
INSTALLED_BIN = '/usr/share/omarchy/bin'


def root():
    explicit = os.environ.get('OMARCHY_TEST_ROOT') or ''
    shell = os.environ.get('OMARCHY_SHELL_PATH') or ''
    if not explicit and shell:
        explicit = str(Path(shell).parent)
    return Path(explicit or '/usr/share/omarchy')


def make(base, app):
    """Returns the environment overrides (OMARCHY_PATH, OMARCHY_SHELL_PATH, PATH)."""
    host = root()
    tree = base / 'omarchy-host'
    (tree / 'bin').mkdir(parents=True)
    (tree / 'shell').symlink_to(host / 'shell', target_is_directory=True)
    if (host / 'default').is_dir():
        (tree / 'default').symlink_to(host / 'default', target_is_directory=True)
    stubs = base / 'stub-bin'
    stubs.mkdir()
    log = base / 'omarchy-calls.log'
    names = {n for n in os.listdir(INSTALLED_BIN) if n.startswith('omarchy-')} if os.path.isdir(INSTALLED_BIN) else set()
    names |= {'omarchy-shell', 'omarchy-hyprland-focus-app', 'omarchy-notification-send'}
    for name in names:
        if name == 'omarchy-shell':
            body = f'#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "{log}"\n[ "$1" = -q ] && shift\nexec qs ipc -n -p "{app}" call "$@"\n'
        elif name == 'omarchy-hyprland-focus-app':
            # Test double of the host script (same contract): focus the newest window whose
            # class matches, through the test's own hyprctl stub.
            body = (f'#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "{log}"\n'
                    'address=$(hyprctl clients -j 2>/dev/null | jq -r --arg p "$1" \'def m($v): ($v // "") | test($p; "i"); '
                    'sort_by(.focusHistoryID) | first((.[] | select(m(.class))), (.[] | select(.initialClass == "org.omarchy.agent" and m(.initialTitle)))).address // empty\')\n'
                    '[[ -n $address ]] || exit 1\n'
                    'hyprctl dispatch "hl.dsp.focus({ window = \\"address:$address\\" })"\n')
        else:
            body = f'#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "{log}"\nexit 0\n'
        for folder in (stubs, tree / 'bin'):
            (folder / name).write_text(body)
            (folder / name).chmod(0o755)
    path = [str(stubs)] + [p for p in os.environ.get('PATH', '').split(':')
                           if p and not p.startswith(REF) and p != INSTALLED_BIN]
    return {'OMARCHY_PATH': str(tree), 'OMARCHY_SHELL_PATH': str(tree / 'shell'), 'PATH': ':'.join(path)}


def check(env, *outputs):
    """Fails when a host script (4.5 reference tree or the installed bin) could run or did."""
    assert not any(p.startswith(REF) or p == INSTALLED_BIN for p in env['PATH'].split(':')), env['PATH']
    assert os.path.realpath(Path(env['OMARCHY_PATH']) / 'bin').startswith(os.path.realpath(Path(env['OMARCHY_PATH']).parent)), 'OMARCHY_PATH/bin must be the stub directory'
    for text in outputs:
        assert REF + '/v45/bin' not in str(text) and INSTALLED_BIN + '/' not in str(text), 'a host script ran'
