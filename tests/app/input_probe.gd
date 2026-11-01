extends Button

var accept_events: int = 0
var presses: int = 0


func _ready() -> void:
	pressed.connect(func(): presses += 1)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel"):
		accept_events += 1
