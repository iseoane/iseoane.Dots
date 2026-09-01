local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- xeoTheme palette shared with zsh, Starship, Herdr, OpenCode and Windows Terminal.
-- Defined inline because only .wezterm.lua is deployed to Windows.
config.color_schemes = {
	["xeoTheme"] = {
		foreground = "#d8dee9",
		background = "#08052b",
		cursor_bg = "#e28ca9",
		cursor_fg = "#14141a",
		cursor_border = "#e28ca9",
		selection_bg = "#2e3440",
		selection_fg = "#d8dee9",
		scrollbar_thumb = "#2e3440",
		split = "#2e3440",
		ansi = {
			"#1b1b22",
			"#e28ca9",
			"#a3be8c",
			"#e5c07b",
			"#81a1c1",
			"#b48ead",
			"#88c0d0",
			"#d8dee9",
		},
		brights = {
			"#4c566a",
			"#f2a4bc",
			"#b1d196",
			"#eed49f",
			"#9bb7d3",
			"#c69ac3",
			"#9ad5df",
			"#eceff4",
		},
		tab_bar = {
			background = "#14141a",
			active_tab = { bg_color = "#2e3440", fg_color = "#e28ca9" },
			inactive_tab = { bg_color = "#202028", fg_color = "#8f93a5" },
			inactive_tab_hover = { bg_color = "#2e3440", fg_color = "#d8dee9" },
			new_tab = { bg_color = "#14141a", fg_color = "#81a1c1" },
			new_tab_hover = { bg_color = "#2e3440", fg_color = "#e28ca9" },
		},
	},
}

config.color_scheme = "xeoTheme"

config.font = wezterm.font("Hack Nerd Font")
config.font_size = 15.0
-- Transparency is independent from the palette. Tuned by eye: 0.95 was
-- invisible, 0.85 subtle, 0.75 still read as too solid. 0.65 is clearly
-- see-through; text keeps its contrast against #08052b, but how readable it
-- actually is now depends on what's behind the window.
-- Kept in step with Windows Terminal's profiles.defaults.opacity (65).
config.window_background_opacity = 0.65
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
config.window_decorations = "RESIZE"
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

wezterm.on("gui-startup", function(cmd)
	local tab, pane, window = wezterm.mux.spawn_window(cmd or {})
	window:gui_window():maximize()
end)

return config
