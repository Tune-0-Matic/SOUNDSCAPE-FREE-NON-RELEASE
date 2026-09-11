class_name Countach
extends Node
## Wireframe Lamborghini Countach, generated entirely from hand-placed Vector3s.
##
## Local space: +Z forward (nose), +Y up, +X right. Wheels sit on y = 0.
## Edges are emitted as a flat PackedVector3Array of point pairs (a,b,a,b,...) and
## built once, because the body never deforms -- only the transform offset moves.
##
## The body is lofted: each station below is a cross-section ring, and consecutive
## rings are rungged together. That is what produces the wedge (nose rings sit low and
## narrow, cabin rings rise and pinch inward) without hand-listing several hundred edges.

## Ring: z, lower half-width, lower y, waist half-width, waist y, top half-width, top y.
## Station 5-6 are the greenhouse: note top half-width collapses to 0.40 while the waist
## stays at 0.72 -- that pinch IS the Countach's narrow cabin over wide hips.
const STATIONS := [
	[ 1.70, 0.22, 0.14, 0.30, 0.24, 0.24, 0.28],  # nose tip, low wedge
	[ 1.45, 0.34, 0.13, 0.44, 0.30, 0.38, 0.36],  # nose break
	[ 1.05, 0.56, 0.12, 0.66, 0.42, 0.56, 0.46],  # front axle
	[ 0.62, 0.62, 0.12, 0.72, 0.46, 0.60, 0.50],  # windscreen base
	[ 0.18, 0.62, 0.12, 0.72, 0.48, 0.40, 0.72],  # roof front
	[-0.42, 0.62, 0.12, 0.72, 0.48, 0.38, 0.72],  # roof rear
	[-0.85, 0.60, 0.12, 0.70, 0.46, 0.56, 0.52],  # rear deck
	[-1.30, 0.54, 0.13, 0.64, 0.44, 0.56, 0.46],  # over rear axle
	[-1.62, 0.44, 0.16, 0.52, 0.40, 0.46, 0.42],  # chopped tail
]

const AXLE_F := 1.05
const AXLE_R := -1.05
const WHEEL_R := 0.26
const WHEEL_X := 0.70

# --- suspension motion ----------------------------------------------------
## High-frequency chassis jitter and a slow lateral drift, both built from detuned sine
## pairs so the cycle never visibly repeats. Amplitudes are deliberately tiny: the road
## is already moving, so the car only has to stop looking welded to the screen.
@export var jitter_amp := 0.009
@export var sway_amp := 0.11

var offset := Vector3.ZERO
var _t := 0.0
var _edges := PackedVector3Array()

func _init() -> void:
	_build()

func _process(delta: float) -> void:
	_t += delta
	offset.y = sin(_t * 47.0) * jitter_amp + sin(_t * 31.3) * jitter_amp * 0.6
	offset.x = sin(_t * 0.37) * sway_amp + sin(_t * 0.23) * sway_amp * 0.55

func edges() -> PackedVector3Array:
	return _edges

# --- construction ---------------------------------------------------------
func _build() -> void:
	_edges = PackedVector3Array()
	_draw_chassis()
	_draw_greenhouse()
	_draw_popups()
	_draw_intakes()
	_draw_spoiler()
	_draw_arches()
	_draw_wheels()

func _edge(a: Vector3, b: Vector3) -> void:
	_edges.push_back(a)
	_edges.push_back(b)

func _loop(pts: Array) -> void:
	for i in pts.size():
		_edge(pts[i], pts[(i + 1) % pts.size()])

## Six points around one station, ordered so the ring closes cleanly:
## lower-left, waist-left, top-left, top-right, waist-right, lower-right.
func _ring(s: Array) -> Array:
	var z: float = s[0]
	return [
		Vector3(-s[1], s[2], z), Vector3(-s[3], s[4], z), Vector3(-s[5], s[6], z),
		Vector3(s[5], s[6], z), Vector3(s[3], s[4], z), Vector3(s[1], s[2], z),
	]

## Lofted body: every station ring, plus longitudinal rails joining like-for-like
## points between consecutive rings. The floor pan closes each ring underneath.
func _draw_chassis() -> void:
	var prev: Array = []
	for s in STATIONS:
		var r := _ring(s)
		_loop(r)
		if not prev.is_empty():
			for i in r.size():
				_edge(prev[i], r[i])
		prev = r
	# door shut lines, front and rear of the cabin
	for x in [-0.72, 0.72]:
		_edge(Vector3(x, 0.46, 0.62), Vector3(x * 0.86, 0.12, 0.62))
		_edge(Vector3(x, 0.48, -0.42), Vector3(x * 0.86, 0.12, -0.42))
		_edge(Vector3(x, 0.30, 0.62), Vector3(x, 0.30, -0.42))   # sill crease

## Steeply raked screen, narrow roof, and the near-vertical rear glass the Countach
## is known for. Drawn as explicit panels so the glass reads separately from the body.
func _draw_greenhouse() -> void:
	var wf := 0.60   # top half-width at the screen base
	var rf := 0.40   # top half-width at the roof
	# windscreen: base station 4 (z 0.62) up to roof front (z 0.18)
	_loop([Vector3(-wf, 0.50, 0.62), Vector3(wf, 0.50, 0.62),
		Vector3(rf, 0.72, 0.18), Vector3(-rf, 0.72, 0.18)])
	_edge(Vector3(0.0, 0.50, 0.62), Vector3(0.0, 0.72, 0.18))    # centre mullion
	# roof panel
	_loop([Vector3(-rf, 0.72, 0.18), Vector3(rf, 0.72, 0.18),
		Vector3(0.38, 0.72, -0.42), Vector3(-0.38, 0.72, -0.42)])
	# rear glass, dropping to the deck
	_loop([Vector3(-0.38, 0.72, -0.42), Vector3(0.38, 0.72, -0.42),
		Vector3(0.56, 0.52, -0.85), Vector3(-0.56, 0.52, -0.85)])
	# side glass, both flanks
	for sx in [-1.0, 1.0]:
		_loop([Vector3(sx * wf, 0.50, 0.62), Vector3(sx * rf, 0.72, 0.18),
			Vector3(sx * 0.38, 0.72, -0.42), Vector3(sx * 0.72, 0.48, -0.42)])

## Pop-up headlights, deployed. Each is a raised pod standing proud of the nose deck,
## with its lens face drawn separately so the light itself reads at low resolution.
func _draw_popups() -> void:
	for sx in [-1.0, 1.0]:
		var x0: float = sx * 0.20
		var x1: float = sx * 0.50
		var zf := 1.36
		var zb := 1.20
		var yb := 0.34   # sits on the nose deck
		var yt := 0.54   # raised height
		# pod box
		_loop([Vector3(x0, yb, zf), Vector3(x1, yb, zf), Vector3(x1, yt, zb), Vector3(x0, yt, zb)])
		_loop([Vector3(x0, yb, zb), Vector3(x1, yb, zb), Vector3(x1, yt, zb), Vector3(x0, yt, zb)])
		_edge(Vector3(x0, yb, zf), Vector3(x0, yb, zb))
		_edge(Vector3(x1, yb, zf), Vector3(x1, yb, zb))
		# lens face, inset
		_loop([Vector3(x0 + sx * 0.04, yb + 0.04, zf - 0.01),
			Vector3(x1 - sx * 0.04, yb + 0.04, zf - 0.01),
			Vector3(x1 - sx * 0.04, yt - 0.03, zb - 0.01),
			Vector3(x0 + sx * 0.04, yt - 0.03, zb - 0.01)])

## Side NACA ducts ahead of the rear arch, plus the boxy shoulder scoops that sit
## behind the side glass -- both are signature Countach details.
func _draw_intakes() -> void:
	for sx in [-1.0, 1.0]:
		var x: float = sx * 0.72
		# NACA duct: a tapered slot let into the flank
		_loop([Vector3(x, 0.24, 0.10), Vector3(x, 0.20, -0.30),
			Vector3(x, 0.38, -0.36), Vector3(x, 0.40, 0.06)])
		_edge(Vector3(x, 0.30, 0.08), Vector3(x, 0.28, -0.33))    # duct centre rib
		# shoulder scoop box behind the cabin
		var xi: float = sx * 0.54
		var xo: float = sx * 0.70
		_loop([Vector3(xi, 0.50, -0.46), Vector3(xo, 0.50, -0.46),
			Vector3(xo, 0.62, -0.62), Vector3(xi, 0.62, -0.62)])
		_loop([Vector3(xi, 0.50, -0.80), Vector3(xo, 0.50, -0.80),
			Vector3(xo, 0.62, -0.62), Vector3(xi, 0.62, -0.62)])
		_edge(Vector3(xi, 0.50, -0.46), Vector3(xi, 0.50, -0.80))
		_edge(Vector3(xo, 0.50, -0.46), Vector3(xo, 0.50, -0.80))

## The rear wing: a flat blade, level across its whole span, carried on two uprights
## off the rear deck. Drawn as a closed box so it has thickness in wireframe.
func _draw_spoiler() -> void:
	var lead := [
		Vector3(-0.62, 0.80, -1.34), Vector3(-0.26, 0.80, -1.34),
		Vector3(0.26, 0.80, -1.34), Vector3(0.62, 0.80, -1.34),
	]
	var trail := []
	for p in lead:
		trail.append(p + Vector3(0.0, 0.0, -0.15))
	for i in lead.size() - 1:
		_edge(lead[i], lead[i + 1])
		_edge(trail[i], trail[i + 1])
	for i in lead.size():
		_edge(lead[i], trail[i])
	# uprights
	for sx in [-1.0, 1.0]:
		var x: float = sx * 0.38
		_edge(Vector3(x, 0.46, -1.34), Vector3(x, 0.80, -1.34))
		_edge(Vector3(x, 0.46, -1.46), Vector3(x, 0.80, -1.46))
		_edge(Vector3(x, 0.46, -1.34), Vector3(x, 0.46, -1.46))

## Flared arches, drawn as arcs standing on the flank plane above each axle.
func _draw_arches() -> void:
	for sx in [-1.0, 1.0]:
		for az in [AXLE_F, AXLE_R]:
			var x: float = sx * 0.76
			var r: float = WHEEL_R + 0.10
			var prev := Vector3.ZERO
			for k in 8:
				var a: float = PI * float(k) / 7.0
				var p := Vector3(x, 0.10 + sin(a) * r, az + cos(a) * r)
				if k > 0:
					_edge(prev, p)
				prev = p

## Octagons rather than circles: at this line weight a circle needs many more segments
## to read as round, and faceted wheels are truer to the vector-graphics era anyway.
func _draw_wheels() -> void:
	for sx in [-1.0, 1.0]:
		for az in [AXLE_F, AXLE_R]:
			var x: float = sx * WHEEL_X
			var rim := []
			for k in 8:
				var a: float = TAU * float(k) / 8.0
				rim.append(Vector3(x, WHEEL_R + sin(a) * WHEEL_R, az + cos(a) * WHEEL_R))
			_loop(rim)
			# hub spokes, every other vertex so it stays legible when small
			var hub := Vector3(x, WHEEL_R, az)
			for k in range(0, 8, 2):
				_edge(hub, rim[k])
