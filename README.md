# Foamy Notification Center

Notification history with app stacks, search, and do not disturb.

![Foamy Notification Center with sample notifications](preview.png)

## Install

Requires Omarchy Quattro with stock notifications or Foamy Notifications enabled, `jq`, and
`inotify-tools`.

Picture previews also require `file` and ImageMagick 7 (`magick`). PNG, JPEG,
GIF, and WebP previews are converted to a single PNG of at most 720 × 720 pixels.
Conversion uses a plugin-local policy: no delegates or disk pixel cache, an
8,192-pixel width/height limit, a 128 MiB pixel cache, a 512 MiB process memory
limit, and a five-second timeout (forced termination after one further second).
Unsupported, oversized, or failed previews are discarded; notification text is
still archived. Missing preview tools also leave notifications without previews.

```sh
omarchy plugin add https://github.com/foamrider/foamy-notification-center.git --enable
```

## Use

- Click the bell to open the center. Click an app heading to expand its stack.
- Click a notification body to open its picture or focus the sending app,
  including the visible card in a collapsed stack.
- Hover to dismiss a stack or individual notification. The trash clears the panel.
- Click search or press `/` to filter. Press Escape to close search.
- Click the silence button, or right-click the bar icon, to toggle do not disturb.

Set `language` on the widget entry in `shell.json`: `system` (default), `en`,
or `nb`. Other system languages fall back to English.

Set `compact` on the widget entry in `shell.json` to `true` for a slim app
header and tighter message spacing. The default, `false`, keeps the roomier
cards. Text and picture sizes stay unchanged. This setting is independent of
Foamy Notifications, which defaults to compact popups.

Cards use the same motion as Foamy popups: a 180 ms fade with an 8 px lift on
arrival and a 120 ms fade on removal. The departed row then collapses over
140 ms so remaining cards move smoothly. The panel height also animates.
Message updates retain their card, and scrolling does not replay the entrance.

Keeps up to 1,000 notifications for 30 days by default. Silenced notifications
remain in history; stock Omarchy exceptions still apply.

The default `clickAction: "Auto"` opens only an absolute PNG, JPEG, GIF, or WebP
path extracted from the notification action; otherwise it tries the live default
action through Foamy Notifications, then falls back to focusing the sending app. Sender commands (`exec` and `execArgv`) are never replayed or kept in the
archive. Existing archived commands are removed on the next sync.
Set `clickAction` to `"Focus the app"` to skip pictures and live actions, or `"Nothing"` to disable
notification body clicks. Closed app callbacks and URL actions cannot be replayed.

When used with Foamy Notifications, activating a popup removes it from this center
and clears its unread state. Dismissing the popup with × or right-click keeps it
in history. The public `foamy.notification-center.store remove` IPC command accepts
comma-separated notification keys and performs a durable removal. The companion
`handled` command only updates the in-memory list after a caller has already
committed that removal; Foamy Notifications uses this to avoid a second archive
rewrite. Both accept at most 100 exact `timestamp-id` keys.

Updates to an existing notification replace its archived content without creating
another unread item. The watcher reconciles at startup and after reconnecting,
then reports source and archive changes. With a custom `XDG_STATE_HOME`, it reads
stock notifications from `~/.local/state/omarchy` and enabled Foamy notifications
from `$XDG_STATE_HOME/omarchy`. The archive remains in `XDG_STATE_HOME` in both
cases. Changing the enabled plugin in `shell.json` reconnects the source watcher. There is no periodic archive polling;
opening the panel also requests a fresh list. Reads which overlap newer events
are retried, and duplicate filesystem events skip retention work.

When Foamy Notifications is running, Auto clicks without pictures request the exact live
notification's default action, letting the browser or app open its own destination.
Foamy keeps live browser callbacks available when popups expire, are hidden, or
are silenced. Clicking those history entries can still open the original destination.
Callbacks are limited to the newest 100 retained actions in the current shell
session. Sender closure, history dismissal or clearing, disabling the center,
and eviction release them. A browser or shell restart cannot restore old callbacks.
Unavailable callbacks, older Foamy versions, and stock Omarchy Notifications
fall back to the stock app-focus helper. No browser mappings are
required for center clicks. Failed focus keeps the entry available with an error.
The center never extracts links from message text or replays archived commands.

Text-only replacements reuse retained images and previews. Each plugin still owns
its own image lifetime and cleanup: the center's longer retention does not depend
on the popup cache. Changed source files invalidate thumbnail reuse; conversion
limits and text-only fallback remain in place.

## Remove

```sh
omarchy plugin remove foamy.notification-center
```

Removing the plugin leaves stock notifications running. Notification history,
saved images, and the current do-not-disturb setting remain on disk. The plugin's
archive and images are under `$XDG_STATE_HOME/omarchy-notification-center`
(default `~/.local/state/omarchy-notification-center`). Stock notification files
under `$XDG_STATE_HOME/omarchy/notifications` are also retained. Review these
directories separately if you want to delete history.

Omarchy manages the plugin entry in `shell.json`. Packages and data outside
the plugin directory are retained unless you remove them separately.

## License

[MIT](LICENSE). Based on [Omarchy Notification Center](https://github.com/jankeesvw/omarchy-notification-center).
Omarchy and Lucide notices are in [LICENSE-OMARCHY](LICENSE-OMARCHY) and
[LICENSE-LUCIDE](LICENSE-LUCIDE).

Provided **as is**, without warranty or guaranteed support. Use at your own risk.

Card animations can be checked with `python3 tests/motion.py` (isolated Qt) or
`python3 tests/motion.py --desktop` (Wayland). Both use synthetic history.

Stock compatibility can be checked without touching personal history:

```sh
python3 tests/stock-runtime.py
python3 tests/stock-runtime.py --custom
```

These checks use a private D-Bus session and temporary home directory.
