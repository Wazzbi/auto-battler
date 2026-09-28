extends Node2D
## Nezničitelný statický objekt (šedý placeholder, viz "Statické objekty ve
## světě" v CLAUDE.md, 2026-09-28) - trvalý landmark, nikdy nezmizí. NA ROZDÍL
## od destructible_object.gd nemá `take_damage()`/HP vůbec a přidává se JEN do
## skupiny "obstacles" (nepřátelé se mu vyhýbají, viz enemy.gd's
## _avoid_obstacles()) - nikdy ne do "destructibles", takže hráčovo cílení
## (player.gd's _find_nearest_targets()) na něj nikdy nenarazí.

## Jak blízko musí být nepřítel, než ho tenhle objekt začne odpuzovat - vyšší
## výchozí hodnota než destructible_object.gd, ať trvalé objekty působí jako
## "pevnější" překážka.
@export var avoid_radius: float = 65.0


func _ready() -> void:
	add_to_group("obstacles")
