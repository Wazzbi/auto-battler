extends Control
## Procedurálně kreslený kosočtverec pro zobrazení rarity karty (schopnost/
## item) - žádný obrázkový asset, stejně jako zbytek vizuálů v projektu (viz
## "Visuals are all procedural" v CLAUDE.md). Barva se nastavuje zvenčí přes
## rarity_color (hud.gd čte GameManager.SHOP_RARITY_COLORS[rarity]).

var rarity_color: Color = Color.WHITE:
	set(value):
		rarity_color = value
		queue_redraw()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var points := PackedVector2Array([
		Vector2(w * 0.5, 0.0),
		Vector2(w, h * 0.5),
		Vector2(w * 0.5, h),
		Vector2(0.0, h * 0.5),
	])
	draw_colored_polygon(points, rarity_color)
	draw_polyline(points + PackedVector2Array([points[0]]), Color(0.0, 0.0, 0.0, 0.5), 1.5, true)
