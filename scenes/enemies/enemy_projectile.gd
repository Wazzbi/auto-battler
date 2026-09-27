extends Node2D
## Projektil vystřelený is_ranged nepřítelem (viz enemy.gd) - letí ROVNĚ ve
## směru spočítaném při vystřelení (viz setup()) k hráči - top-down pivot
## 2026-09-27, dřív letěl natvrdo vodorovně vlevo (opačný směr než hráčovo
## scenes/projectiles/projectile.gd). NEHOMÍ, pokud se hráč mezitím pohne -
## stejné chování jako hráčův projektil, jen zrcadlený zdroj/cíl.
##
## DŮLEŽITÉ - zásah řeší JEN proti přiřazenému cíli (hráči), NIKDY neprohledává
## skupinu "enemies" jako náhradní cíl, i kdyby se `target` mezitím stal
## neplatným. Tohle je přesně ten "Design constraint for future enemy
## projectiles" z CLAUDE.md: protože se nepřátelé navzájem neblokují a mohou
## se vizuálně překrývat (viz enemy.gd), generický "zasáhni cokoliv v dosahu"
## fallback by je nechal střílet jeden druhého do zad. Hráčovo projectile.gd
## takový fallback MÁ (hledá nejbližšího nepřítele) - tenhle skript záměrně ne.

@export var speed: float = 400.0
## Jak blízko svého STŘEDU musí projektil dolétnout k hráči, aby se počítal
## zásah - napevno tady, ne čtené z cíle jako u hráčova projectile.gd, protože
## nepřátelské projektily mají jediný možný typ cíle (hráč), žádnou potřebu
## univerzálnosti pro různě velké cíle.
@export var hit_radius: float = 22.0
## O kolik px za okrajem AKTUÁLNÍHO záběru kamery (v libovolném směru) se
## projektil ještě považuje za platný, než se automaticky zničí
@export var cleanup_margin: float = 100.0

var damage: float = 5.0
var target: Node2D = null
var direction: Vector2 = Vector2.LEFT


## Zavolá nepřítel hned po instanciaci (viz enemy.gd's _shoot_projectile()) -
## spočítá i směr letu z hráčovy pozice V TOMHLE OKAMŽIKU, stejný guard proti
## nulovému vektoru jako v hráčově projectile.gd.
func setup(dmg: float, target_node: Node2D = null) -> void:
	damage = dmg
	target = target_node
	if target_node != null and global_position.distance_squared_to(target_node.global_position) > 0.0001:
		direction = global_position.direction_to(target_node.global_position)


func _process(delta: float) -> void:
	position += direction * speed * delta

	if target != null and is_instance_valid(target):
		if global_position.distance_to(target.global_position) <= hit_radius:
			target.take_damage(damage)
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
