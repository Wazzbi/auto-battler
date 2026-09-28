extends Node2D
## Krátký plovoucí text efektu (viz "Sebratelné předměty" v CLAUDE.md) -
## vypíše se na místě sebrání, postupně stoupá a mizí, pak se sám zničí.
## Stejný self-freeing tween princip jako impact_effect.gd (tween_method/
## tween_property -> tween.tween_callback(queue_free)), jen nad Label místo
## _draw().

@export var rise_distance: float = 40.0
@export var duration: float = 1.0

@onready var label: Label = $Label


## Volá se explicitně (ne z _ready()) - stejný důvod jako projectile.gd's
## setup(): text/barva musí být nastavené PŘED spuštěním tweenu, a volající
## kód (pickup_base.gd) je nastavuje až po instantiate()/add_child().
func setup(text: String, color: Color = Color.WHITE) -> void:
	label.text = text
	label.modulate = color

	var tween := create_tween()
	tween.tween_property(label, "position:y", label.position.y - rise_distance, duration)
	tween.parallel().tween_property(label, "modulate:a", 0.0, duration)
	tween.tween_callback(queue_free)
