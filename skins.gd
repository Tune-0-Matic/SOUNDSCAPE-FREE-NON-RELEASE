class_name Skins
## Whole-program colour schemes. Every stylebox in player.tscn is a shared sub-resource,
## so recolouring the resource in place repaints every panel that uses it -- no need to
## rebuild the theme or touch individual nodes.

const NAMES := ["WIN98", "MAROON", "MIDNIGHT", "AMBER", "TOKYO", "TERMINAL", "ICE",
	"VAPORWAVE", "MIAMI", "C64", "HAZARD"]

## Schemes may set a second accent. Where they do, "accent2" drives the filled
## indicators (progress bars, fader tracks, list selection) while "accent" keeps the
## text highlights -- that split is what makes the two-tone skins read as two-tone
## instead of one hue smeared over everything. Mono skins just omit it.

const SCHEMES := {
	# Default: Windows 98 industrial grey chassis, black material parts.
	"WIN98": {
		"window": Color(0.847, 0.855, 0.827), "panel": Color(0.886, 0.886, 0.875),
		"border": Color(0.29, 0.333, 0.408), "header": Color(0, 0, 0),
		"header_text": Color(1, 1, 1), "text": Color(0, 0, 0),
		"screen": Color(0, 0, 0), "screen_text": Color(0.769, 0.788, 0.741),
		"accent": Color(0.18, 0.8, 0.443),
	},
	"MAROON": {
		"window": Color(0.192, 0.075, 0.086), "panel": Color(0.259, 0.106, 0.118),
		"border": Color(0.463, 0.212, 0.227), "header": Color(0, 0, 0),
		"header_text": Color(0.976, 0.827, 0.694), "text": Color(0.949, 0.788, 0.647),
		"screen": Color(0.055, 0.016, 0.02), "screen_text": Color(0.882, 0.667, 0.545),
		"accent": Color(0.847, 0.267, 0.271), "accent2": Color(0.902, 0.663, 0.259),
	},
	"VAPORWAVE": {
		"window": Color(0.145, 0.098, 0.216), "panel": Color(0.208, 0.137, 0.298),
		"border": Color(0.443, 0.290, 0.612), "header": Color(0, 0, 0),
		"header_text": Color(0.482, 0.933, 0.945), "text": Color(0.925, 0.780, 0.988),
		"screen": Color(0.043, 0.020, 0.086), "screen_text": Color(0.792, 0.671, 0.973),
		"accent": Color(1.0, 0.353, 0.749), "accent2": Color(0.365, 0.918, 0.937),
	},
	"MIAMI": {
		"window": Color(0.055, 0.243, 0.263), "panel": Color(0.086, 0.325, 0.345),
		"border": Color(0.192, 0.514, 0.529), "header": Color(0, 0, 0),
		"header_text": Color(1.0, 0.855, 0.400), "text": Color(0.902, 0.976, 0.969),
		"screen": Color(0.016, 0.086, 0.098), "screen_text": Color(0.706, 0.937, 0.925),
		"accent": Color(1.0, 0.290, 0.549), "accent2": Color(1.0, 0.804, 0.290),
	},
	"C64": {
		"window": Color(0.416, 0.353, 0.804), "panel": Color(0.518, 0.463, 0.859),
		"border": Color(0.259, 0.204, 0.643), "header": Color(0, 0, 0),
		"header_text": Color(0.647, 0.596, 0.918), "text": Color(0.106, 0.075, 0.353),
		"screen": Color(0.157, 0.118, 0.482), "screen_text": Color(0.702, 0.663, 0.937),
		"accent": Color(0.647, 0.596, 0.918), "accent2": Color(0.925, 0.859, 0.588),
	},
	"HAZARD": {
		"window": Color(0.118, 0.114, 0.098), "panel": Color(0.180, 0.169, 0.137),
		"border": Color(0.376, 0.337, 0.196), "header": Color(0, 0, 0),
		"header_text": Color(1.0, 0.843, 0.161), "text": Color(0.906, 0.859, 0.678),
		"screen": Color(0.043, 0.039, 0.031), "screen_text": Color(0.859, 0.780, 0.478),
		"accent": Color(1.0, 0.796, 0.078), "accent2": Color(1.0, 0.427, 0.086),
	},
	"MIDNIGHT": {
		"window": Color(0.07, 0.078, 0.11), "panel": Color(0.106, 0.118, 0.157),
		"border": Color(0.227, 0.247, 0.322), "header": Color(0, 0, 0),
		"header_text": Color(0.902, 0.902, 0.902), "text": Color(0.784, 0.8, 0.847),
		"screen": Color(0.02, 0.024, 0.039), "screen_text": Color(0.6, 0.64, 0.72),
		"accent": Color(0.18, 0.8, 0.443),
	},
	"AMBER": {
		"window": Color(0.169, 0.129, 0.094), "panel": Color(0.227, 0.173, 0.118),
		"border": Color(0.42, 0.325, 0.204), "header": Color(0, 0, 0),
		"header_text": Color(1.0, 0.761, 0.4), "text": Color(1.0, 0.702, 0.278),
		"screen": Color(0.039, 0.027, 0.016), "screen_text": Color(1.0, 0.651, 0.169),
		"accent": Color(1.0, 0.651, 0.169),
	},
	"TOKYO": {
		"window": Color(0.102, 0.071, 0.149), "panel": Color(0.141, 0.102, 0.2),
		"border": Color(0.353, 0.239, 0.478), "header": Color(0, 0, 0),
		"header_text": Color(1.0, 0.373, 0.824), "text": Color(0.847, 0.776, 1.0),
		"screen": Color(0.024, 0.012, 0.063), "screen_text": Color(0.788, 0.62, 1.0),
		"accent": Color(1.0, 0.184, 0.71),
	},
	"TERMINAL": {
		"window": Color(0.039, 0.059, 0.039), "panel": Color(0.063, 0.094, 0.063),
		"border": Color(0.184, 0.29, 0.184), "header": Color(0, 0, 0),
		"header_text": Color(0.49, 1.0, 0.49), "text": Color(0.271, 0.851, 0.271),
		"screen": Color(0, 0, 0), "screen_text": Color(0.224, 1.0, 0.078),
		"accent": Color(0.224, 1.0, 0.078),
	},
	"ICE": {
		"window": Color(0.8, 0.839, 0.871), "panel": Color(0.867, 0.898, 0.918),
		"border": Color(0.29, 0.373, 0.42), "header": Color(0, 0, 0),
		"header_text": Color(1, 1, 1), "text": Color(0.063, 0.133, 0.169),
		"screen": Color(0, 0.031, 0.059), "screen_text": Color(0.616, 0.792, 0.867),
		"accent": Color(0.216, 0.835, 0.949),
	},
}

static func apply(theme: Theme, root: Control, name: String) -> void:
	var s: Dictionary = SCHEMES.get(name, SCHEMES["WIN98"])
	var a2: Color = s.get("accent2", s.accent)
	# root chassis is a per-node override, not a theme entry
	var chassis: StyleBoxFlat = root.get("theme_override_styles/panel")
	if chassis:
		chassis.bg_color = s.window

	for spec in [["PanelContainer", "panel"], ["Button", "normal"], ["Button", "hover"],
			["Button", "pressed"], ["Button", "focus"]]:
		var sb: StyleBoxFlat = theme.get_stylebox(spec[1], spec[0])
		if sb:
			sb.border_color = s.border
	_flat(theme, "PanelContainer", "panel").bg_color = s.panel
	_flat(theme, "Header", "panel").bg_color = s.header
	_flat(theme, "Screen", "panel").bg_color = s.screen
	_flat(theme, "Screen", "panel").border_color = s.border
	_flat(theme, "Button", "normal").bg_color = s.panel
	_flat(theme, "Button", "hover").bg_color = s.border
	_flat(theme, "Button", "pressed").bg_color = s.header
	_flat(theme, "ProgressBar", "background").bg_color = s.screen
	_flat(theme, "ProgressBar", "background").border_color = s.border
	_flat(theme, "ProgressBar", "fill").bg_color = a2
	_flat(theme, "ItemList", "panel").bg_color = s.screen
	_flat(theme, "ItemList", "panel").border_color = s.border
	_flat(theme, "ItemList", "selected").bg_color = a2
	_flat(theme, "ItemList", "selected_focus").bg_color = a2
	for style in ["grabber_area", "grabber_area_highlight"]:
		_flat(theme, "VSlider", style).bg_color = a2
	_flat(theme, "VSlider", "slider").bg_color = s.screen
	_flat(theme, "VSlider", "slider").border_color = s.border
	_flat(theme, "PopupMenu", "panel").bg_color = s.screen
	_flat(theme, "PopupMenu", "panel").border_color = s.border
	_flat(theme, "PopupMenu", "hover").bg_color = a2
	theme.set_color("font_color", "PopupMenu", s.screen_text)
	theme.set_color("font_hover_color", "PopupMenu", s.screen)
	theme.set_color("font_color", "LineEdit", s.screen_text)
	theme.set_color("font_placeholder_color", "LineEdit", Color(s.screen_text, 0.45))
	theme.set_color("caret_color", "LineEdit", a2)
	for axis in ["VScrollBar", "HScrollBar"]:
		_flat(theme, axis, "scroll").bg_color = s.screen
		_flat(theme, axis, "scroll").border_color = s.border
		_flat(theme, axis, "grabber").bg_color = s.panel
		_flat(theme, axis, "grabber").border_color = s.header

	theme.set_color("font_color", "Label", s.text)
	theme.set_color("font_color", "HeaderLabel", s.header_text)
	theme.set_color("font_color", "Green", s.accent)
	theme.set_color("font_color", "Button", s.text)
	theme.set_color("font_hover_color", "Button", s.header_text if s.window.get_luminance() < 0.4 else s.text)
	theme.set_color("font_pressed_color", "Button", s.accent)
	theme.set_color("font_color", "ItemList", s.screen_text)
	theme.set_color("font_selected_color", "ItemList", s.screen)
	theme.set_color("font_selected_color", "TabContainer", s.header_text)
	theme.set_color("font_unselected_color", "TabContainer", s.text)
	theme.set_color("font_hovered_color", "TabContainer", s.text)
	_flat(theme, "TabContainer", "tab_unselected").bg_color = s.panel
	_flat(theme, "TabContainer", "tab_unselected").border_color = s.border
	_flat(theme, "TabContainer", "tab_selected").bg_color = s.header
	_flat(theme, "TabContainer", "tabbar_background").bg_color = s.window
	_flat(theme, "TabContainer", "panel").bg_color = s.panel

static func _flat(theme: Theme, type: String, name: String) -> StyleBoxFlat:
	var sb := theme.get_stylebox(name, type)
	return sb as StyleBoxFlat if sb is StyleBoxFlat else StyleBoxFlat.new()
