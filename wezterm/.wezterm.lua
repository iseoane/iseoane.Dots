local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- xeoTheme mirrors the active Tokyo Night system palette; the cursor uses the fuchsia active window border.
-- Defined inline because only .wezterm.lua is deployed to Windows.
config.color_schemes = {
	["xeoTheme"] = {
		foreground = "#a9b1d6",
		background = "#1a1b26",
		cursor_bg = "#ff2e9a",
		cursor_fg = "#13141c",
		cursor_border = "#ff2e9a",
		selection_bg = "#292e42",
		selection_fg = "#a9b1d6",
		scrollbar_thumb = "#292e42",
		split = "#292e42",
		ansi = {
			"#0e0e14",
			"#f7768e",
			"#9ece6a",
			"#e0af68",
			"#7aa2f7",
			"#ad8ee6",
			"#449dab",
			"#a9b1d6",
		},
		brights = {
			"#565f89",
			"#ff7a93",
			"#b9f27c",
			"#ff9e64",
			"#7da6ff",
			"#bb9af7",
			"#0db9d7",
			"#c0caf5",
		},
		tab_bar = {
			background = "#13141c",
			active_tab = { bg_color = "#292e42", fg_color = "#ff2e9a" },
			inactive_tab = { bg_color = "#24283b", fg_color = "#414868" },
			inactive_tab_hover = { bg_color = "#292e42", fg_color = "#a9b1d6" },
			new_tab = { bg_color = "#13141c", fg_color = "#7aa2f7" },
			new_tab_hover = { bg_color = "#292e42", fg_color = "#ff2e9a" },
		},
	},
}

config.color_scheme = "xeoTheme"

-- Installed Nerd Font; it supplies both coding glyphs and prompt icons.
config.font = wezterm.font("JetBrainsMono Nerd Font")
config.font_size = 12.0
-- A mostly opaque background keeps terminal text readable while Hyprland blur
-- softens the wallpaper behind it. Kept in step with Windows Terminal (85).
config.window_background_opacity = 0.85
config.macos_window_background_blur = 50
if wezterm.target_triple:find("linux") then
	config.enable_wayland = true
	config.wayland_window_background_blur = true
end
-- Windows counterpart to macos_window_background_blur: without a system
-- backdrop the opacity above reads as a plain see-through window rather
-- than a blur. Ignored on Linux/macOS, and on Windows 10 (needs Win11).
config.win32_system_backdrop = "Acrylic"
config.hide_tab_bar_if_only_one_tab = true
config.window_decorations = "TITLE|RESIZE"
config.window_padding = {
	left = 12,
	right = 12,
	top = 10,
	bottom = "1cell",
}

config.enable_kitty_keyboard = false

if wezterm.target_triple:find("windows") then
	config.default_domain = "WSL:Debian"
	config.launch_menu = {
		{
			label = "PowerShell",
			args = { "pwsh.exe", "-NoLogo" },
		},
		{
			label = "WSL: Debian",
			domain = { DomainName = "WSL:Debian" },
		},
	}
end

config.mouse_bindings = {
	-- Selección normal
	{
		event = { Down = { streak = 1, button = "Left" } },
		mods = "NONE",
		action = wezterm.action.SelectTextAtMouseCursor("Cell"),
	},

	-- Completar selección y copiar
	{
		event = { Up = { streak = 1, button = "Left" } },
		mods = "NONE",
		action = wezterm.action.CompleteSelection("ClipboardAndPrimarySelection"),
	},

	-- Botón derecho pega
	{
		event = { Down = { streak = 1, button = "Right" } },
		mods = "NONE",
		action = wezterm.action.PasteFrom("Clipboard"),
	},
}

return config
