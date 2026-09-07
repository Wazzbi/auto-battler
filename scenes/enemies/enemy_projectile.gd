extends Node2D
## Projektil vystřelený is_ranged nepřítelem (viz enemy.gd) - létá VLEVO
## k hráči (opačný směr než hráčovo scenes/projectiles/projectile.gd, které
## létá vpravo k nepřátelům).
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
## O kolik px za LEVÝM okrajem aktuálního záběru kamery se projektil ještě
## považuje za platný, než se automaticky zničí (zrcadlový protějšek
## cleanup_margin v hráčově projectile.gd, který hlídá pravý okraj)
@export var cleanup_margin: float = 100.0

var damage: float = 5.0
var target: Node2D = null


## Zavolá nepřítel hned po instanciaci (viz enemy.gd's _shoot_projectile())
func setup(dmg: float, target_node: Node2D = null) -> void:
	damage = dmg
	target = target_node


func _process(delta: float) -> void:
	position.x -= speed * delta

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
	var half_width: float = get_viewport().get_visible_rect().size.x / 2.0
	if global_position.x < camera.global_position.x - half_width - cleanup_margin:
		queue_free()
