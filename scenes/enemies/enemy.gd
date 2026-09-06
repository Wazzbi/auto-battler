extends Node2D
## Základní nepřítel. Pohybuje se doleva směrem k hráči; jakmile je
## dostatečně blízko, zastaví se a útočí v pravidelných intervalech.
## Rozestup od ostatních nepřátel řeší _get_effective_stop_distance() -
## bez toho by se všichni zastavili přesně na stejné pozici a vizuálně
## by se překrývali v jedné hromadě.

@export var speed: float = 80.0
@export var max_hp: float = 20.0
@export var contact_damage: float = 5.0
@export var attack_interval: float = 1.0
@export var melee_range: float = 60.0
@export var reward: int = 10
## Minimální odstup od dalšího nepřítele, který je blíž hráči
@export var min_spacing: float = 45.0

var hp: float
var player_ref: Node2D = null
var attack_timer: float = 0.0
## Náhodná odchylka, díky které se nepřátelé nezastaví přesně na jedné čáře
var melee_range_jitter: float = 0.0


func _ready() -> void:
	add_to_group("enemies")
	hp = max_hp
	player_ref = get_tree().get_first_node_in_group("player")
	melee_range_jitter = randf_range(-15.0, 60.0)


func _process(delta: float) -> void:
	if GameManager.state != GameManager.State.PLAYING:
		return
	if player_ref == null or not is_instance_valid(player_ref):
		return

	var distance: float = global_position.distance_to(player_ref.global_position)
	var stop_distance: float = _get_effective_stop_distance(distance)

	if distance > stop_distance:
		global_position.x -= speed * delta
	else:
		attack_timer -= delta
		if attack_timer <= 0.0:
			player_ref.take_damage(contact_damage)
			attack_timer = attack_interval


## Pokud je jiný nepřítel blíž hráči než já, zastavím se o kus dál za ním
## namísto na stejné pozici - vytváří to přirozenou "frontu" místo hromady.
func _get_effective_stop_distance(my_distance: float) -> float:
	var my_target: float = melee_range + melee_range_jitter

	for other in get_tree().get_nodes_in_group("enemies"):
		if other == self or not is_instance_valid(other):
			continue
		var other_distance: float = other.global_position.distance_to(player_ref.global_position)
		if other_distance < my_distance and other_distance > my_target - min_spacing:
			my_target = other_distance + min_spacing

	return my_target


func take_damage(amount: float) -> void:
	hp -= amount
	if hp <= 0:
		_die()


func _die() -> void:
	GameManager.enemy_defeated(reward)
	queue_free()
