extends Node2D
## Projektil letí vodorovně doprava k přiřazenému cíli. Zásah se řeší přes
## kontrolu vzdálenosti (žádné fyzikální collision vrstvy) - spolehlivé
## pro prototyp. DŮLEŽITÉ: úklid mimo obrazovku počítá se skutečnou
## pozicí KAMERY, ne s pevnou souřadnicí velikosti okna - jinak by
## projektily mizely téměř okamžitě po vystřelení, jakmile hráč postoupí
## dostatečně daleko levelem (world-space X hráče roste, ale porovnávat
## ho přímo s velikostí viewportu v pixelech nedává smysl).
##
## Dosah zásahu NENÍ pevná konstanta - čte se z `hit_radius` cílového
## nepřítele (enemy.gd), protože různě velcí nepřátelé (např. 3x větší
## Elite) potřebují různě velký poloměr, aby zásah vizuálně odpovídal
## tomu, kdy projektil doopravdy dolétne k okraji jejich siluety.

@export var speed: float = 600.0
## O kolik px za pravým okrajem AKTUÁLNÍHO záběru kamery se projektil
## ještě považuje za platný, než se automaticky zničí
@export var cleanup_margin: float = 100.0

var damage: float = 10.0
var target: Node2D = null


## Zavolá hráč hned po instanciaci - nastaví poškození a konkrétní cíl,
## na který projektil letí (kvůli multishot upgradu, aby více projektilů
## nemířilo náhodně na stejného nejbližšího nepřítele).
func setup(dmg: float, target_node: Node2D = null) -> void:
	damage = dmg
	target = target_node


func _process(delta: float) -> void:
	position.x += speed * delta

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
	var half_width: float = get_viewport().get_visible_rect().size.x / 2.0
	if global_position.x > camera.global_position.x + half_width + cleanup_margin:
		queue_free()
