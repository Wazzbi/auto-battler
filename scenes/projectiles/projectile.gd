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
## Dosah, ve kterém "Rikošet" (viz _resolve_hit() níže) hledá další cíl po
## zásahu - nezávislé od hráčova attack_range (to řeší jen PRVNÍ zacílení).
const RICOCHET_RADIUS: float = 260.0
## Poškození dalšího odrazu je NIŽŠÍ než předchozí (ne plné) - stejná
## "odraz je slabší než přímý zásah" logika jako u většiny podobných her v
## žánru, ať se Rikošet nestane čistě strictly lepší variantou víc cílů
## bez jakéhokoliv trade-off.
const RICOCHET_DAMAGE_FALLOFF: float = 0.7

var damage: float = 10.0
var target: Node2D = null
var direction: Vector2 = Vector2.RIGHT
## Kdo tenhle projektil vystřelil - potřeba jen pro trigger "on_kill"
## (Řetězová detonace), viz _resolve_hit() níže. Enemy projektily
## (enemy_projectile.gd) jsou samostatný skript a tohle nemají.
var shooter: Node2D = null
## Zbývající počet nepřátel, skrz které projektil ještě PROLÉTNE po
## zásahu (trigger "always", schopnost "Průbojné střely") - nastaveno
## jednou v setup(), dekrementuje se v _resolve_hit().
var pierce_remaining: int = 0
## Zbývající počet odrazů na dalšího nepřítele (trigger "always",
## schopnost "Rikošet") - viz pierce_remaining výše, stejný vzor.
var ricochet_remaining: int = 0
## Cíle, které tenhle projektil už zasáhl - brání opakovanému zásahu
## stejného nepřítele při Průbojných střelách (projektil letí dál stejným
## směrem a jinak by mohl znovu "najet" na toho samého, než ho mine) a při
## Rikošetu (neodráží se zpátky na právě zasaženého).
var _hit_targets: Array[Node2D] = []


## Zavolá hráč hned po instanciaci - nastaví poškození, konkrétní cíl (kvůli
## multishot upgradu, aby více projektilů nemířilo náhodně na stejného
## nejbližšího nepřítele), střelce a pierce/ricochet magnitudu (viz
## player.gd's get_pierce_count()/get_ricochet_count()) a směr letu
## spočítaný z cílovy pozice V TOMHLE OKAMŽIKU. Guard proti nulovému vektoru
## (cíl přesně na pozici střelce) - `normalized()` by jinak tiše vrátil
## Vector2.ZERO a projektil by stál na místě místo aby letěl - radši zůstat
## u výchozího Vector2.RIGHT.
func setup(dmg: float, target_node: Node2D = null, shooter_node: Node2D = null, pierce_count: int = 0, ricochet_count: int = 0) -> void:
	damage = dmg
	target = target_node
	shooter = shooter_node
	pierce_remaining = pierce_count
	ricochet_remaining = ricochet_count
	if target_node != null and global_position.distance_squared_to(target_node.global_position) > 0.0001:
		direction = global_position.direction_to(target_node.global_position)


func _process(delta: float) -> void:
	position += direction * speed * delta

	if target != null and is_instance_valid(target) and not _hit_targets.has(target):
		if global_position.distance_to(target.global_position) <= target.hit_radius:
			_resolve_hit(target)
			return
	else:
		# Přiřazený cíl mezitím zmizel (např. ho zabil jiný projektil), NEBO
		# právě proletěl skrz Průbojné střely (target se vynuluje v
		# _resolve_hit()) - zkus zasáhnout cokoliv nejbližšího v dosahu,
		# mimo _hit_targets (ať neprobije/neodrazí se na stejného nepřítele
		# dvakrát).
		for enemy in get_tree().get_nodes_in_group("enemies"):
			if not is_instance_valid(enemy) or _hit_targets.has(enemy):
				continue
			if global_position.distance_to(enemy.global_position) <= enemy.hit_radius:
				_resolve_hit(enemy)
				return

	_cleanup_if_off_screen()


## Vyřeší jeden zásah - vždy aplikuje poškození, pak rozhodne, jestli
## projektil zanikne, nebo pokračuje dál (Průbojné střely) / se odrazí
## (Rikošet). Destructible objekty (ne "enemies") pierce/ricochet/on_kill
## logiku vůbec nevidí - zasáhne se a projektil zanikne jako dřív.
func _resolve_hit(hit: Node2D) -> void:
	hit.take_damage(damage)
	_hit_targets.append(hit)

	if not hit.is_in_group("enemies"):
		queue_free()
		return

	if hit.has_method("is_dead") and hit.is_dead() and shooter != null and is_instance_valid(shooter) and shooter.has_method("register_projectile_kill"):
		shooter.register_projectile_kill(hit.global_position)

	if pierce_remaining > 0:
		pierce_remaining -= 1
		target = null
		return

	if ricochet_remaining > 0:
		var next_target: Node2D = _find_ricochet_target(hit.global_position)
		if next_target != null:
			ricochet_remaining -= 1
			target = next_target
			direction = global_position.direction_to(next_target.global_position)
			damage *= RICOCHET_DAMAGE_FALLOFF
			return

	queue_free()


## Nejbližší jiný nepřítel (mimo _hit_targets) uvnitř RICOCHET_RADIUS od
## místa posledního zásahu, nebo null, pokud žádný není.
func _find_ricochet_target(from_pos: Vector2) -> Node2D:
	var best: Node2D = null
	var best_dist: float = RICOCHET_RADIUS
	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(enemy) or _hit_targets.has(enemy):
			continue
		var dist: float = from_pos.distance_to(enemy.global_position)
		if dist <= best_dist:
			best = enemy
			best_dist = dist
	return best


func _cleanup_if_off_screen() -> void:
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		return
	var half_size: Vector2 = get_viewport().get_visible_rect().size / 2.0
	var local_pos: Vector2 = global_position - camera.get_screen_center_position()
	if absf(local_pos.x) > half_size.x + cleanup_margin or absf(local_pos.y) > half_size.y + cleanup_margin:
		queue_free()
