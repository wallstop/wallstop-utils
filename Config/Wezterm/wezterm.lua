local wezterm = require 'wezterm'
local config = {}

-- In newer versions of wezterm, use the config_builder which will help provide cleaner error messages
if wezterm.config_builder then
  config = wezterm.config_builder()
end

-- Cross-platform shell detection
local function get_default_shell()
  -- Check common shell locations in order of preference
  local shells = {
    '/opt/homebrew/bin/zsh',  -- macOS Homebrew (Apple Silicon)
    '/usr/local/bin/zsh',     -- macOS Homebrew (Intel) / Linux
    '/bin/zsh',               -- macOS default / some Linux
    '/usr/bin/zsh',           -- Linux default
    '/bin/bash',              -- Fallback to bash
    '/usr/bin/bash',          -- Linux bash
  }
  
  for _, shell in ipairs(shells) do
    local f = io.open(shell, 'r')
    if f then
      f:close()
      return { shell }
    end
  end
  
  -- If no shell found, let wezterm use its default
  return nil
end

-- Set default shell using cross-platform detection
local default_shell = get_default_shell()
if default_shell then
  config.default_prog = default_shell
end

-- Mouse configuration
config.hide_mouse_cursor_when_typing = false
config.mouse_bindings = {
  -- Make mouse cursor always visible
  {
    event = { Up = { streak = 1, button = 'Left' } },
    action = wezterm.action.CompleteSelection 'PrimarySelection',
  },
}

-- Key bindings
config.keys = {
  -- Split vertically with Ctrl+Shift++ (Plus)
  {
    key = '+',
    mods = 'CTRL|SHIFT',
    action = wezterm.action.SplitHorizontal { domain = 'CurrentPaneDomain' },
  },
  -- Split horizontally with Ctrl+Shift+- (Minus)
  {
    key = '_',
    mods = 'CTRL',
    action = wezterm.action.SplitVertical { domain = 'CurrentPaneDomain' },
  },
  {
    key = '-',
    mods = 'CTRL',
    action = wezterm.action.DisableDefaultAssignment,
  },
  {
    key = '-',
    mods = 'CTRL|SHIFT',
    action = wezterm.action.SplitVertical { domain = 'CurrentPaneDomain' }, 
  },
  {
    key = '_',
    mods = 'SHIFT|CTRL',
    action = wezterm.action.SplitVertical { domain = 'CurrentPaneDomain' },
  },
  {
    key = '-',
    mods = 'SUPER',
    action = wezterm.action.DisableDefaultAssignment,
  },
  -- Close current pane with Ctrl+Shift+W
  {
    key = 'w',
    mods = 'CTRL|SHIFT',
    action = wezterm.action.CloseCurrentPane { confirm = false },
  },
  -- Navigate between panes
  {
    key = 'UpArrow',
    mods = 'CTRL',
    action = wezterm.action.ActivatePaneDirection 'Up',
  },
  {
    key = 'RightArrow',
    mods = 'CTRL',
    action = wezterm.action.ActivatePaneDirection 'Right',
  },
  {
    key = 'LeftArrow',
    mods = 'CTRL',
    action = wezterm.action.ActivatePaneDirection 'Left',
  },
  {
    key = 'DownArrow',
    mods = 'CTRL',
    action = wezterm.action.ActivatePaneDirection 'Down',
  },
  {
    key = 'v',
    mods = 'CTRL',
    action = wezterm.action.PasteFrom 'Clipboard',
  },
  -- Copy with Ctrl+C if selection exists, otherwise send interrupt
  {
    key = 'c',
    mods = 'CTRL',
    action = wezterm.action_callback(function(window, pane)
      local has_selection = window:get_selection_text_for_pane(pane) ~= ''
      if has_selection then
        window:perform_action(
          wezterm.action.CopyTo 'Clipboard',
          pane
        )
        window:perform_action(wezterm.action.ClearSelection, pane)
      else
        window:perform_action(
          wezterm.action.SendKey { key = 'c', mods = 'CTRL' },
          pane
        )
      end
    end),
  },
}

-- Optional: Additional mouse settings
config.enable_scroll_bar = true
config.scrollback_lines = 10000

return config
