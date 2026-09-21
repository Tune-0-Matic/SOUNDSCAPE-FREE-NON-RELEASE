extends Control
## Terminal boot screen. Reveals a fake POST sequence character by character, then either
## asks for a name (first run) or greets the stored one, and gets out of the way.
##
## Text is drawn into a plain Label and the name is captured from raw key events rather
## than a LineEdit: a LineEdit drags in a caret, selection and focus styling that would
## all need theming to match, for a field used exactly once.

signal finished(user_name: String)

const LINES := [
	"SOUNDSCAPE FREE VER BY ZFACTORPSX v1.0",
	"",
	"MEM TEST 65536K ............ OK",
	"DETECTING AUDIO DEVICE ..... WASAPI 96000HZ",
	"MOUNTING LIBRARY ........... %d TRACKS",
	"LOADING DSP CHAIN .......... EQ21/SHELF/DRIVE",
	"SPECTRUM ANALYSER .......... 32 BANDS",
	"VIDEO MODE ................. 1920x1080",
	"CALIBRATING PHOSPHOR ....... OK",
	"",
]
const MESSAGE := """Welcome To SOUNDSCAPE!
You Are Currently On The Free Version. It is a SOLID Media Player.
Please Check Out The Full Version By Going To The "STATS" Tab!
Also, Check Out The Discord!
Enjoy The Visualizers!!!!
-ZFACTORPSX"""
const CHARS_PER_SEC := 150.0
const MAX_NAME := 16

enum Phase { BOOT, ASK, WELCOME, DONE }

var user_name := ""
var track_count := 0

var _phase: Phase = Phase.BOOT
var _buf := ""
var _shown := 0.0
var _started := false
var _returning := false
var _typed := ""
var _blink := 0.0
@onready var _label: Label = $Text
@onready var _bg: ColorRect = $BG

func begin(saved_name: String, tracks: int) -> void:
	user_name = saved_name
	track_count = tracks
	_buf = "\n".join(LINES) % tracks
	_started = true
	_returning = not user_name.is_empty()
	if _returning:
		_buf += "\nCOMPLETE\n"      # returning user: the POST reports done, then greets
	visible = true

func _process(delta: float) -> void:
	# Nothing runs until begin() hands over. Without this the state machine ticks from
	# frame 0 against an empty buffer, decides the POST is already finished, and drops
	# straight to the name prompt -- which is exactly what the logo intro exposed by
	# delaying begin() by three seconds.
	if not _started:
		return
	# read the palette every frame: the skin is applied after this node is ready, and
	# the user can be mid-boot when it lands
	var accent := get_theme_color("font_color", "Green")
	_label.add_theme_color_override("font_color", accent)
	_bg.color = get_theme_color("font_color", "ItemList").darkened(0.97)
	_blink += delta

	match _phase:
		Phase.BOOT:
			_shown += delta * CHARS_PER_SEC
			if _shown >= float(_buf.length()):
				_phase = Phase.ASK if user_name.is_empty() else Phase.WELCOME
		Phase.ASK:
			pass                     # waiting on the keyboard
		Phase.WELCOME:
			pass                     # waits for SPACE; the greeting is not a timed splash
	_redraw()

func _redraw() -> void:
	var out := _buf.substr(0, int(_shown))
	match _phase:
		Phase.ASK:
			out += "\nENTER NAME: " + _typed + _caret()
		Phase.WELCOME:
			out += "\nWELCOME BACK " if _returning else "\nWELCOME "
			out += user_name + "\n\n" + MESSAGE + "\n\nPRESS SPACE TO ENTER " + _caret()
	_label.text = out

func _caret() -> String:
	return "_" if fmod(_blink, 0.9) < 0.45 else " "

## Raw key capture. Only active while the prompt is up, and every key is consumed so a
## stray SPACE cannot reach the transport underneath.
func _unhandled_key_input(event: InputEvent) -> void:
	if _phase != Phase.ASK and _phase != Phase.WELCOME:
		return
	var k := event as InputEventKey
	if not k or not k.pressed:
		return
	if _phase == Phase.WELCOME:
		if k.keycode == KEY_SPACE or k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
			_phase = Phase.DONE
			visible = false
			finished.emit(user_name)
		accept_event()
		return
	if k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER:
		if not _typed.strip_edges().is_empty():
			user_name = _typed.strip_edges().to_upper()
			_buf += "\nCOMPLETE\n"
			_shown = float(_buf.length())
			_phase = Phase.WELCOME
	elif k.keycode == KEY_BACKSPACE:
		_typed = _typed.left(_typed.length() - 1)
	elif k.unicode >= 32 and _typed.length() < MAX_NAME:
		_typed += String.chr(k.unicode)
	accept_event()
