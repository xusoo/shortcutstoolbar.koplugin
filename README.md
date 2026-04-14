# Shortcuts Toolbar

Shortcuts Toolbar adds a configurable shortcut bar to KOReader's reader and file-browser menus.

It gives you quick access to common actions, optional reader information, and separate shortcut layouts for the reader and the file browser.

## What the plugin does

- Adds a toolbar home state to the reader menu.
- Adds a toolbar to the file browser, either inside the menu or as a persistent top bar.
- Can show book info, time, battery, and a back-to-library button in the reader.
- Lets you enable, disable, and reorder built-in and custom shortcuts.
- Supports custom shortcuts based on menu actions, dispatcher actions, or patch callbacks.
- Includes a patch API for adding shortcuts from startup patches.

## Available shortcuts

Reader-only shortcuts:

- Font
- Bookmarks
- Search
- Table of contents
- Page browser
- Book status

Shared shortcuts:

- Frontlight
- Night mode
- Wi-Fi
- Time
- Battery
- Calendar statistics
- Restart KOReader
- Spacer
- Spacer

File-browser shortcuts:

- Cloud storage
- OPDS catalog
- Favorites
- Collections
- File search

But you can also add your own custom shortcuts through the plugin's patch API or from the `Custom shortcuts` submenu.

## Custom shortcuts

Custom shortcuts can be added from the `Custom shortcuts` submenu.

Reader custom shortcuts are stored separately. File browser and SimpleUI custom shortcuts share the same list, so changes made from either place are reflected in both.

Each custom shortcut can have its own name, icon, and action source.

Supported action sources:

- `System action`: runs a dispatcher action directly.
- `Menu action`: records and replays a KOReader menu path.
- `Patch callback`: executes a Lua callback registered by a startup patch.

## Patch API

The patch API is documented in `PATCH_API.md` and a ready-to-copy example is included at `examples/2-shortcutstoolbar-custom-shortcut.lua.sample`.

Patches register through KOReader's `userpatch` hook:

```lua
local userpatch = require("userpatch")

userpatch.registerPatchPluginFunc("shortcutstoolbar", function()
    local ok, Shortcuts = pcall(require, "custom_shortcut_manager")
    if not ok then return end

    Shortcuts.ensureShortcut{
        id = "my_patch.hello",
        name = "Hello",
        icon_file = Shortcuts.getBundledIcon("smile.svg"),
        callback = function(menu, shortcut)
            -- your action here
        end,
    }
end)
```

Patch API notes:

- `Shortcuts.ensureShortcut{ ... }` creates or updates a patch-owned shortcut.
- If `view` is omitted, the shortcut is registered for `reader`, `fb`, and `simpleui`.
- `Shortcuts.deleteShortcut("my_patch.hello")` removes a patch-owned shortcut.
- Registered shortcuts still need to be enabled from `Configure shortcuts` for the relevant view.

## SimpleUI integration

When the SimpleUI plugin is installed, Shortcuts Toolbar can add a `Shortcuts Toolbar` module to the home screen.

The SimpleUI module provides:

- A home-screen shortcut row.
- Its own icon-size setting.
- Its own shortcut selection.
- The same custom shortcut list used by the file browser.
- Its own reset action.

SimpleUI module settings are available under `Home Screen -> Modules -> Module Settings`.

Patch callbacks can also target the SimpleUI module by registering a shortcut with `view = "simpleui"` or by omitting `view` and letting the plugin register it for all supported views.