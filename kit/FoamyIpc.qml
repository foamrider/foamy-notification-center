// foamy-kit 0.1.0 5a372861e53b40a49d0d97cc2796f89231337a9c40700f26a0fcb694d70d2a9b — do not edit; change foamy-kit and run sync
import QtQuick
import Quickshell.Io
import "FoamyIpcResolver.js" as Resolver

// A plugin IPC target that works on 4.0 and takes the 4.5 fast path.
//
// It is an IpcHandler (so `qs ipc call <target> <fn>` works on both
// versions) that also registers with 4.5's IpcRegistry, exactly like the
// stock ShellIpc does, so `omarchy-shell <target> <fn>` is answered over the
// shell socket (~5 ms) instead of a qs ipc client (~45 ms). Declare typed
// functions as on any IpcHandler:
//
//   FoamyIpc {
//     target: "foamy.audio"
//     enabled: member.isLeader          // one live handler per shell, not per monitor
//     function toggle(): void { root.toggle() }
//     function status(): string { return JSON.stringify(root.statusObject()) }
//   }
//
// Declare no extra properties, signals or helper functions here or on the
// instance: IpcHandler exposes them to callers. Put helpers on the panel.
// Whether the fast path is live: Resolver.fastPath(anyObject) from
// "FoamyIpcResolver.js".
IpcHandler {
  id: handler

  Component.onCompleted: {
    var registry = Resolver.registry(handler)
    if (registry) registry.register(handler)
  }
  Component.onDestruction: {
    var registry = Resolver.registry(handler)
    if (registry) registry.unregister(handler)
  }
}
