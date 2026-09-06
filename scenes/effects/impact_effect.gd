extends Node2D
## Krátký vizuální efekt dopadu - rozšiřující se a mizející prstenec
## + jádro. Používá se při dopadu hráče na zem (drop-in animace).
## Žádný externí asset, čistě vykreslené přes _draw().

@export var duration: float = 0.4
@export var max_radius: float = 55.0
@export var color: Color = Color(1.0, 0.85, 0.5, 0.9)

var _radius: float = 4.0
var _alpha: float = 0.9


func _ready() -> void:
	var tween := create_tween()
	tween.tween_method(_set_radius, 4.0, max_radius, duration)
	tween.parallel().tween_method(_set_alpha, color.a, 0.0, duration)
	tween.tween_callback(queue_free)


func _set_radius(value: float) -> void:
	_radius = value
	queue_redraw()


func _set_alpha(value: float) -> void:
	_alpha = value
	queue_redraw()


func _draw() -> void:
	var ring_color := color
	ring_color.a = _alpha
	draw_arc(Vector2.ZERO, _radius, 0.0, TAU, 32, ring_color, 5.0, true)

	var core_color := color
	core_color.a = _alpha * 0.4
	draw_circle(Vector2.ZERO, _radius * 0.35, core_color)
