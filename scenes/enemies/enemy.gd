extends Node2D
## Základní nepřítel. Pohybuje se doleva směrem k hráči; jakmile je
## dostatečně blízko (podle svého vlastního melee_range), zastaví se a útočí
## v pravidelných intervalech - buď kontaktně (výchozí), nebo na dálku
## projektilem, pokud je zapnuté is_ranged (viz ranged_enemy.tscn).
##
## Nepřátelé se navzájem NEBLOKUJÍ - každý počítá svou stop distanci nezávisle
## na ostatních, takže se klidně vizuálně překryjí (žádná Area2D/collision
## řešená spacing logika, viz "combat resolution is distance-based" v
## CLAUDE.md). To je záměr: jednotky s různou rychlostí (např. pomalý Elite
## a rychlí normální nepřátelé) se tak nezasekávají jedna za druhou.

@export var speed: float = 80.0
@export var max_hp: float = 20.0
@export var contact_damage: float = 5.0
@export var attack_interval: float = 1.0
## Vzdálenost, na které se nepřítel zastaví a začne útočit. U kontaktních
## nepřátel je to prakticky dosah "na dotek", u is_ranged nepřátel funguje
## jako skutečný dostřel (viz ranged_enemy.tscn, kde je nastavený mnohem výš).
@export var melee_range: float = 60.0
@export var reward: int = 10
## Zkušenosti za zabití - hráč z nich sbírá úrovně a body do schopností
@export var xp_reward: int = 12
## Jak blízko svého STŘEDU musí projektil dolétnout, aby se počítal zásah.
## Musí zhruba odpovídat polovině šířky vizuálu (Polygon2D), jinak zásah
## vypadá, že se stane příliš brzy/pozdě vůči tomu, co je vidět na obrazovce -
## viz projectile.gd, které čte tuhle hodnotu místo vlastní pevné konstanty.
@export var hit_radius: float = 20.0

## Pokud je zapnuté, útok nedává kontaktní poškození přímo, ale vystřelí
## projektil (enemy_projectile.gd) směrem k hráči - viz _shoot_projectile().
@export var is_ranged: bool = false
## Scéna projektilu, kterou is_ranged nepřítel vystřeluje. Musí to být
## enemy_projectile.tscn (nebo kompatibilní) - NIKDY hráčovo projectile.tscn,
## to má opačný směr letu a jiný fallback při ztrátě cíle (viz CLAUDE.md
## "Design constraint for future enemy projectiles").
@export var projectile_scene: PackedScene

var hp: float
var player_ref: Node2D = null
var attack_timer: float = 0.0
## Náhodná odchylka, díky které se nepřátelé nezastaví přesně na jedné čáře
var melee_range_jitter: float = 0.0
## Hlídá dvojité započítání smrti - queue_free() odstraní uzel ze stromu až
## na konci snímku, takže do té doby je pořád validní. Když dva projektily
## trefí stejného nepřítele ve stejném snímku (typicky při multishotu nebo
## rychlé střelbě na nízké HP), take_damage() by se bez tohoto flagu zavolal
## dvakrát a enemies_alive by kleslo o 2 místo o 1 - ve výsledku hra
## považovala vlnu za dočištěnou dřív, než byli všichni nepřátelé opravdu mrtví.
var _is_dead: bool = false


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
	var stop_distance: float = melee_range + melee_range_jitter

	if distance > stop_distance:
		global_position.x -= speed * delta
	else:
		attack_timer -= delta
		if attack_timer <= 0.0:
			if is_ranged:
				_shoot_projectile()
			else:
				player_ref.take_damage(contact_damage)
			attack_timer = attack_interval


## Vystřelí projektil směrem k hráči - contact_damage se tu recykluje jako
## poškození projektilu (u kontaktního nepřítele je to totéž číslo, jen jinak
## doručené, takže není potřeba samostatný export navíc).
func _shoot_projectile() -> void:
	if projectile_scene == null:
		return
	var projectile: Node2D = projectile_scene.instantiate()
	get_tree().current_scene.add_child(projectile)
	projectile.global_position = global_position
	projectile.setup(contact_damage, player_ref)


func take_damage(amount: float) -> void:
	if _is_dead:
		return
	hp -= amount
	if hp <= 0:
		_die()


func _die() -> void:
	if _is_dead:
		return
	_is_dead = true
	GameManager.enemy_defeated(reward, xp_reward)
	queue_free()
