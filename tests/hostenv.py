"""Offscreen test host: load the host's shell QML (and data) only, never its scripts.

Tests target Omarchy 4.5: by default the installed /usr/share/omarchy (its shell/
is 4.5.0, whatever /usr/share/omarchy/version says). OMARCHY_TEST_ROOT (an Omarchy
tree with shell/ and default/) selects another tree; FOAMY_HOST_45 or
OMARCHY_SHELL_PATH (a shell/ directory, as for foamy-kit's harness) select its parent.
Omarchy 4.0 is opt-in: host40() is the tree FOAMY_HOST_40 names, else None (skip).
Only `shell/` and `default/` are exposed through a private OMARCHY_PATH; its `bin/`
and every `omarchy-*` on PATH are logging stubs. `omarchy-shell` reaches this test's
own shell only (qs ipc -p APP), never the live session. check() asserts no host
script (the selected tree's bin/ or the installed one) could run or did. An
AppImage's LD_LIBRARY_PATH (e.g. an editor's bundled libnotify) is dropped, so
notify-send and the shell load the system libraries.
"""
import os
from pathlib import Path

INSTALLED_BIN = '/usr/share/omarchy/bin'


def root():
    explicit = os.environ.get('OMARCHY_TEST_ROOT') or ''
    for shell in (os.environ.get('FOAMY_HOST_45'), os.environ.get('OMARCHY_SHELL_PATH')):
        if not explicit and shell:
            explicit = str(Path(shell).parent)
    return Path(explicit or '/usr/share/omarchy')


def host40():
    """The Omarchy 4.0 tree FOAMY_HOST_40 (a shell/ directory) names, or None."""
    shell = os.environ.get('FOAMY_HOST_40') or ''
    return Path(shell).parent if shell else None


def host_bins():
    return {os.path.realpath(root() / 'bin'), os.path.realpath(INSTALLED_BIN)}


def library_path():
    """LD_LIBRARY_PATH without an AppImage's bundled libraries ($APPDIR)."""
    appdir = (os.environ.get('APPDIR') or '').rstrip('/')
    return ':'.join(p for p in os.environ.get('LD_LIBRARY_PATH', '').split(':')
                    if p and not (appdir and (p == appdir or p.startswith(appdir + '/'))))


def make(base, app):
    """Returns the environment overrides (OMARCHY_PATH, OMARCHY_SHELL_PATH, PATH, LD_LIBRARY_PATH)."""
    host = root()
    tree = base / 'omarchy-host'
    (tree / 'bin').mkdir(parents=True)
    (tree / 'shell').symlink_to(host / 'shell', target_is_directory=True)
    if (host / 'default').is_dir():
        (tree / 'default').symlink_to(host / 'default', target_is_directory=True)
    stubs = base / 'stub-bin'
    stubs.mkdir()
    log = base / 'omarchy-calls.log'
    names = {n for b in host_bins() if os.path.isdir(b) for n in os.listdir(b) if n.startswith('omarchy-')}
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
    bins = host_bins()
    path = [str(stubs)] + [p for p in os.environ.get('PATH', '').split(':')
                           if p and os.path.realpath(p) not in bins]
    return {'OMARCHY_PATH': str(tree), 'OMARCHY_SHELL_PATH': str(tree / 'shell'), 'PATH': ':'.join(path),
            'LD_LIBRARY_PATH': library_path()}


def check(env, *outputs):
    """Fails when a host script (the selected tree's bin/ or the installed one) could run or did."""
    bins = host_bins()
    assert not any(os.path.realpath(p) in bins for p in env['PATH'].split(':') if p), env['PATH']
    assert os.path.realpath(Path(env['OMARCHY_PATH']) / 'bin').startswith(os.path.realpath(Path(env['OMARCHY_PATH']).parent)), 'OMARCHY_PATH/bin must be the stub directory'
    named = bins | {str(root() / 'bin'), INSTALLED_BIN}
    for text in outputs:
        assert not any(b + '/' in str(text) for b in named), 'a host script ran'
