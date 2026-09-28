extends Node2D
## Sdílený základ pro sebratelné předměty (kosočtverce, viz "Sebratelné
## předměty" v CLAUDE.md) - řeší společnou detekci/sebrání/úklid; konkrétní
## efekt a podmínku sebratelnosti implementují potomci (heal_pickup.gd/
## speed_pickup.gd) přes _can_be_collected()/_apply_effect(). Na rozdíl od
## destructible_object.gd/indestructible_object.gd (statické překážky) tenhle
## typ objektu NENÍ v "obstacles" skupině vůbec - hráč jím musí moct volně
## projít, aby ho sebral.

## Jak blízko hráč musí být, aby se kosočtverec sebral - stejný "walk-into"
## princip jako dřívější (smazaný) ability_pickup.gd.
@export var pickup_radius: float = 30.0
@export var floating_text_scene: PackedScene
## Barva plovoucího textu při sebrání - typicky stejná jako vlastní vizuál
## kosočtverce, nastavená per-scéně (viz heal_pickup.tscn/speed_pickup.tscn).
@export var floating_text_color: Color = Color.WHITE


func _process(_delta: float) -> void:
	if GameManager.state != GameManager.State.PLAYING:
		return
	var player: Node2D = get_tree().get_first_node_in_group("player")
	if player == null:
		return
	if global_position.distance_to(player.global_position) > pickup_radius:
		return
	if not _can_be_collected(player):
		return
	_spawn_floating_text(_apply_effect(player))
	queue_free()


## Přepsat v potomkovi - vrátí false, pokud sebrání zrovna nemá smysl (viz
## heal_pickup.gd - hráč na 100 % HP kosočtverec nesebere).
func _can_be_collected(_player: Node2D) -> bool:
	return true


## Přepsat v potomkovi - aplikuje skutečný efekt a vrátí text pro plovoucí
## popisek (prázdný řetězec = žádný text se nezobrazí).
func _apply_effect(_player: Node2D) -> String:
	return ""


func _spawn_floating_text(text: String) -> void:
	if floating_text_scene == null or text == "":
		return
	var effect: Node2D = floating_text_scene.instantiate()
	get_tree().current_scene.add_child(effect)
	effect.global_position = global_position
	effect.setup(text, floating_text_color)
