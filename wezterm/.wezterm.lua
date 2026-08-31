local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- ── Color schemes ────────────────────────────────────────────────────────
-- Gentleman palette, as used by gentle-ai and Gentleman.Dots. Canonical source:
-- Gentleman-Programming/gentleman-kanagawa-blur ->
--   lua/gentleman_kanagawa_blur/variant.lua       (semantic roles)
--   extras/ghostty/gentleman-kanagawa-blur        (16 ANSI + bg/fg/cursor)
-- Defined inline rather than as a colors/*.toml file because only
-- .wezterm.lua itself is deployed to the Windows $HOME (see README).
--
-- To switch themes, change config.color_scheme below to one of:
--   "Gentleman Blur"    Gentleman dark  (default; matches nvim + herdr + starship)
--   "Gentleman Sakura"  Gentleman pink-dark variant
--   "rose-pine-moon"    previous scheme (wezterm built-in)
config.color_schemes = {
	["Gentleman Blur"] = {
		foreground = "#f3f6f9",
		background = "#06080f",

		cursor_bg = "#e0c15a",
		cursor_fg = "#06080f",
		cursor_border = "#e0c15a",

		selection_bg = "#263356",
		selection_fg = "#f3f6f9",

		-- black, red, green, yellow, blue, magenta, cyan, white
		ansi = {
			"#06080f",
			"#cb7c94",
			"#b7cc85",
			"#ffe066",
			"#6fa0af",
			"#ff8dd7",
			"#7aa89f",
			"#f3f6f9",
		},
		brights = {
			"#8a8fa3",
			"#de8fa8",
			"#d1e8a9",
			"#fff7b1",
			"#a3d4d5",
			"#ffaeea",
			"#7fb4ca",
			"#f3f6f9",
		},

		-- gray3 / gray2 from variant.lua: pane splits and inactive chrome.
		split = "#313342",

		tab_bar = {
			background = "#06080f",
			active_tab = { bg_color = "#232a40", fg_color = "#f3f6f9" },
			inactive_tab = { bg_color = "#06080f", fg_color = "#5c6170" },
			inactive_tab_hover = { bg_color = "#1c212c", fg_color = "#f3f6f9" },
			new_tab = { bg_color = "#06080f", fg_color = "#5c6170" },
			new_tab_hover = { bg_color = "#1c212c", fg_color = "#e0c15a" },
		},
	},

	["Gentleman Sakura"] = {
		foreground = "#f3f6f9",
		background = "#1a2033",

		cursor_bg = "#ffb2d7",
		cursor_fg = "#1a2033",
		cursor_border = "#ffb2d7",

		selection_bg = "#ffb2d7",
		selection_fg = "#1a2033",

		ansi = {
			"#1a2033",
			"#ff6f99",
			"#b4e7c7",
			"#ffff00",
			"#7cb1dd",
			"#ffb2d7",
			"#96d8f6",
			"#f3f6f9",
		},
		brights = {
			"#8ba7c1",
			"#ff89b5",
			"#d7ffea",
			"#fff6a1",
			"#b3e6ff",
			"#ffd7f2",
			"#cbf0ff",
			"#ffffff",
		},

		split = "#2a3048",

		tab_bar = {
			background = "#1a2033",
			active_tab = { bg_color = "#2a3048", fg_color = "#f3f6f9" },
			inactive_tab = { bg_color = "#1a2033", fg_color = "#8ba7c1" },
			inactive_tab_hover = { bg_color = "#232a36", fg_color = "#f3f6f9" },
			new_tab = { bg_color = "#1a2033", fg_color = "#8ba7c1" },
			new_tab_hover = { bg_color = "#232a36", fg_color = "#ffb2d7" },
		},
	},
}

config.color_scheme = "Gentleman Blur"

config.font = wezterm.font("Hack Nerd Font")
config.font_size = 15.0
-- Transparency: the Gentleman palette is a *blur* theme (its variant.lua
-- declares bg_dark = "none" and gentle-ai injects background: "none"), so it
-- is designed to sit on a see-through ground. Tuned by eye: 0.95 was
-- invisible, 0.85 subtle, 0.75 still read as too solid. 0.65 is clearly
-- see-through; text keeps its contrast against #06080f, but how readable it
-- actually is now depends on what's behind the window.
-- Kept in step with Windows Terminal's profiles.defaults.opacity (65).
config.window_background_opacity = 0.65
config.macos_window_background_blur = 50
-- Windows counterpart to macos_window_background_blur: without a system
-- backdrop the opacity above reads as a plain see-through window rather
-- than a blur. Ignored on Linux/macOS, and on Windows 10 (needs Win11).
config.win32_system_backdrop = "Acrylic"
config.hide_tab_bar_if_only_one_tab = true
config.window_decorations = "RESIZE"

config.enable_kitty_keyboard = false

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
