extends Control
## Procedurálně kreslená ikonka oka (otevřené/zavřené) pro tlačítko Debug
## panelu - žádný obrázkový asset, stejně jako zbytek vizuálů v projektu
## (viz "Visuals are all procedural" v CLAUDE.md).

@export var eye_color: Color = Color(0.9, 0.9, 0.95, 1.0)

## Otevřené oko = panel je vidět, zavřené = panel je skrytý.
var is_open: bool = false:
	set(value):
		is_open = value
		queue_redraw()


func _draw() -> void:
	var center: Vector2 = size / 2.0

	if is_open:
		# Elipsa (oko) přes nerovnoměrné škálování kruhu, pak zornice navrch.
		draw_set_transform(center, 0.0, Vector2(1.5, 1.0))
		draw_circle(Vector2.ZERO, size.y * 0.42, eye_color)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		draw_circle(center, size.y * 0.16, Color(0.08, 0.08, 0.1, 1.0))
	else:
		# Zavřené víčko - jednoduchá čára s náznakem řas do stran.
		var half_w: float = size.x * 0.4
		draw_line(center + Vector2(-half_w, 0.0), center + Vector2(half_w, 0.0), eye_color, 2.0, true)
		draw_line(center + Vector2(-half_w, 0.0), center + Vector2(-half_w + 3.0, 4.0), eye_color, 2.0, true)
		draw_line(center + Vector2(half_w, 0.0), center + Vector2(half_w - 3.0, 4.0), eye_color, 2.0, true)
