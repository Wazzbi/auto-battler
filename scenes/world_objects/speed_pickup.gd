extends "res://scenes/world_objects/pickup_base.gd"
## Bílý kosočtverec - dočasně zvýší hráčovu rychlost pohybu (viz
## player.gd's apply_speed_buff()/get_move_speed()). Vždy sebratelný -
## sebrání dalšího kusu při už aktivním efektu prostě obnoví plné trvání
## (žádné sčítání procent, viz player.gd).

@export var speed_bonus_percent: float = 0.15
@export var buff_duration: float = 30.0


func _ready() -> void:
	add_to_group("speed_pickups")


func _apply_effect(player: Node2D) -> String:
	player.apply_speed_buff(speed_bonus_percent, buff_duration)
	return "+%d%% rychlost pohybu" % int(round(speed_bonus_percent * 100))
