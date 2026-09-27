extends Node2D
## Zelený kosočtverec, který dropne na místo smrti nepřítele, jenž překročil
## další kumulativní práh zabití (viz GameManager.enemy_defeated()/
## _ability_kill_threshold(), "Schopnosti na základě zabití" v CLAUDE.md).
## Hráč ho sebere pouhým průchodem nablízko (žádný klik/tlačítko, stejný
## "gem pickup" princip jako ve Vampire Survivors) - jakmile je v dosahu
## pickup_radius, ihned vyžádá nabídku schopností (GameManager.
## request_ability_offer(), stejná fronta jako dřív spouštěl časovač nebo
## konec vlny) a sám se zničí. Zmizí HNED při doteku, ne až po skutečném
## výběru v panelu - vizuálně nerozeznatelné (panel hru pauzne prakticky ve
## stejném snímku), ale jednodušší a bez rizika, že by dva současně ležící
## kosočtverce spletly, který patří ke které nabídce (explicit user
## rozhodnutí 2026-09-27).

@export var pickup_radius: float = 40.0

var _player_ref: Node2D = null
var _collected: bool = false


func _ready() -> void:
	add_to_group("ability_pickups")
	_player_ref = get_tree().get_first_node_in_group("player")


func _process(_delta: float) -> void:
	if _collected or GameManager.state != GameManager.State.PLAYING:
		return
	if _player_ref == null or not is_instance_valid(_player_ref):
		return

	if global_position.distance_to(_player_ref.global_position) <= pickup_radius:
		_collected = true
		GameManager.request_ability_offer()
		queue_free()
