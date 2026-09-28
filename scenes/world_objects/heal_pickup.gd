extends "res://scenes/world_objects/pickup_base.gd"
## Zelený kosočtverec - okamžitě uzdraví hráče. Nesebere se, dokud má hráč
## 100 % HP (viz _can_be_collected() níže), takže čeká ve světě, dokud ho
## hráč skutečně nepotřebuje.

@export var heal_amount: float = 15.0


func _ready() -> void:
	add_to_group("heal_pickups")


func _can_be_collected(player: Node2D) -> bool:
	return player.hp < player.max_hp


func _apply_effect(player: Node2D) -> String:
	player.heal(heal_amount)
	return "uzdravení %d HP" % int(heal_amount)
