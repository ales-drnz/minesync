# minesync_guard

`minesync-guard` sits between the app and the Minecraft server so the server
never outlives MineSync: it relays the console and stops the whole process
tree when the app goes away (process group and subreaper on Linux, process
group on macOS, Job Object on Windows). `lib/` is the app side (`GuardClient`).

Test with `dart test`; `bin/fake_minecraft.dart` stands in for a server.
