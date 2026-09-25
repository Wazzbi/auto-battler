extends Control
## Procedurálně kreslený zelený trojúhelník (šipka nahoru) - signalizuje, že
## tahle nabídka v AbilityDraftPanel VYLEPŠÍ schopnost, kterou hráč už
## vlastní (viz GameManager.is_ability_owned() - hud.gd nastavuje visible
## podle toho). Žádný obrázkový asset, stejná konvence jako eye_icon.gd/
## rarity_icon.gd.

const ARROW_COLOR := Color(0.3, 0.85, 0.35)


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var points := PackedVector2Array([
		Vector2(w * 0.5, 0.0),
		Vector2(w, h),
		Vector2(0.0, h),
	])
	draw_colored_polygon(points, ARROW_COLOR)
	draw_polyline(points + PackedVector2Array([points[0]]), Color(0.0, 0.0, 0.0, 0.5), 1.5, true)
