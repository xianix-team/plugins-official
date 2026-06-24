# Installation

This plugin installs directly into your local Claude Code environment. No Xianix configuration is required.

## Steps

1. Copy this folder into your Claude Code plugins directory, or register its path in your `.claude.json`:

   ```bash
   # Option A: copy
   cp -r ux-mob-process-plugin ~/.claude/plugins/ux-mob-process-plugin

   # Option B: register path in .claude.json
   # Add the folder path to the "plugins" array in ~/.claude.json
   ```

2. Reload Claude Code.

3. Verify the plugin loaded:

   ```text
   /ux-mob-process:ux-status
   ```

   You should see: `[ux-mob-process] loaded`

> **Note:** Xianix is not involved in this installation. The plugin runs entirely within your Claude Code environment.
