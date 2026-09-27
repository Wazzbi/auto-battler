extends Node2D
## Projektil letí ROVNĚ ve směru spočítaném při vystřelení (viz setup()) k
## přiřazenému cíli - top-down pivot 2026-09-27, dřív letěl natvrdo vodorovně
## doprava. NEHOMÍ za cílem, pokud se mezitím pohne - míří jen jednou, na
## místo, kde cíl byl v okamžiku vystřelení. Zásah se řeší přes kontrolu
## vzdálenosti (žádné fyzikální collision vrstvy) - spolehlivé pro prototyp.
## DŮLEŽITÉ: úklid mimo obrazovku počítá se skutečnou pozicí KAMERY (přes
## get_screen_center_position(), ne global_position - stejný důvod jako u
## ground.gd kvůli position_smoothing_enabled), ne s pevnou souřadnicí
## velikosti okna - jinak by projektily mizely téměř okamžitě po vystřelení,
## jakmile se hráč vzdálí od počátku (world-space pozice hráče roste, ale
## porovnávat ji přímo s velikostí viewportu v pixelech nedává smysl).
##
## Dosah zásahu NENÍ pevná konstanta - čte se z `hit_radius` cílového
## nepřítele (enemy.gd), protože různě velcí nepřátelé (např. 3x větší
## Elite) potřebují různě velký poloměr, aby zásah vizuálně odpovídal
## tomu, kdy projektil doopravdy dolétne k okraji jejich siluety.

@export var speed: float = 600.0
## O kolik px za okrajem AKTUÁLNÍHO záběru kamery (v libovolném směru) se
## projektil ještě považuje za platný, než se automaticky zničí
@export var cleanup_margin: float = 100.0

var damage: float = 10.0
var target: Node2D = null
var direction: Vector2 = Vector2.RIGHT


## Zavolá hráč hned po instanciaci - nastaví poškození, konkrétní cíl (kvůli
## multishot upgradu, aby více projektilů nemířilo náhodně na stejného
## nejbližšího nepřítele) a směr letu spočítaný z cílovy pozice V TOMHLE
## OKAMŽIKU. Guard proti nulovému vektoru (cíl přesně na pozici střelce) -
## `normalized()` by jinak tiše vrátil Vector2.ZERO a projektil by stál na
## místě místo aby letěl - radši zůstat u výchozího Vector2.RIGHT.
func setup(dmg: float, target_node: Node2D = null) -> void:
	damage = dmg
	target = target_node
	if target_node != null and global_position.distance_squared_to(target_node.global_position) > 0.0001:
		direction = global_position.direction_to(target_node.global_position)


func _process(delta: float) -> void:
	position += direction * speed * delta

	if target != null and is_instance_valid(target):
		if global_position.distance_to(target.global_position) <= target.hit_radius:
			target.take_damage(damage)
			queue_free()
			return
	else:
		# Přiřazený cíl mezitím zmizel (např. ho zabil jiný projektil) -
		# zkus zasáhnout cokoliv nejbližšího v dosahu.
		for enemy in get_tree().get_nodes_in_group("enemies"):
			if not is_instance_valid(enemy):
				continue
			if global_position.distance_to(enemy.global_position) <= enemy.hit_radius:
				enemy.take_damage(damage)
				queue_free()
				return

	_cleanup_if_off_screen()


func _cleanup_if_off_screen() -> void:
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		return
	var half_size: Vector2 = get_viewport().get_visible_rect().size / 2.0
	var local_pos: Vector2 = global_position - camera.get_screen_center_position()
	if absf(local_pos.x) > half_size.x + cleanup_margin or absf(local_pos.y) > half_size.y + cleanup_margin:
		queue_free()
