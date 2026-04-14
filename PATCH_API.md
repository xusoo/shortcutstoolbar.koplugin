# Shortcutstoolbar Patch API

Custom shortcuts can be created from a startup patch without touching raw `G_reader_settings` tables.

Copy the sample file at `plugins/shortcutstoolbar.koplugin/examples/2-shortcutstoolbar-custom-shortcut.lua.sample` into your KOReader user `patches` directory and rename it to `2-shortcutstoolbar-custom-shortcut.lua` if you want to enable it.

Registration only adds the shortcut to the available custom shortcut pool. It does not enable the shortcut in any toolbar automatically. Enable it afterward from the relevant `Configure shortcuts` screen.

Patch entry point:

```lua
local userpatch = require("userpatch")

userpatch.registerPatchPluginFunc("shortcutstoolbar", function()
    local ok, Shortcuts = pcall(require, "custom_shortcut_manager")
    if not ok then return end

    -- register shortcuts here
end)
```

Patch callback shortcut:

```lua
userpatch.registerPatchPluginFunc("shortcutstoolbar", function()
    local ok, Shortcuts = pcall(require, "custom_shortcut_manager")
    if not ok then return end

    Shortcuts.ensureShortcut{
        id = "my_patch.hello",
        name = "Hello",
        icon_file = Shortcuts.getBundledIcon("smile.svg"),
        callback = function(menu, shortcut)
            local UIManager = require("ui/uimanager")
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = "Hello world!",
                timeout = 2,
            })
        end,
    }
end)
```

The callback receives the live menu instance as its first argument and the stored shortcut table as its second.

View selection:

```lua
Shortcuts.ensureShortcut{ id = "only_fb", view = "fb", ... }
Shortcuts.ensureShortcut{ id = "reader_and_simpleui", view = { "reader", "simpleui" }, ... }
Shortcuts.ensureShortcut{ id = "all_views", ... }
```

If `view` is omitted, the shortcut is registered for `reader`, `fb`, and `simpleui`.

Deletion:

```lua
Shortcuts.deleteShortcut("my_patch.hello")
```

`id` is the stable patch-owned identifier. The helper keeps the internal shortcut key private and updates existing entries in place on startup. The userpatch hook may fire more than once during a session as KOReader creates plugin instances, so registration should stay idempotent.