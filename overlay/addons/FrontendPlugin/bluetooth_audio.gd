extends Node

# Send launcher audio to the Bluetooth headset. The card worker bluetooth.sh
# writes the ALSA device and the marker file when a headset has an audio link.

# The engine lists only ALSA names that start with "plughw".
const DEVICE := "plughw_socket_bluetooth"

var _marker: String = (OS.get_environment("SOCKET_RUN") if OS.has_environment("SOCKET_RUN") else "/tmp/socket").path_join("bluetooth.audio")
var _applied := "Default"
var _poll_at := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if Time.get_ticks_msec() < _poll_at:
		return
	_poll_at = Time.get_ticks_msec() + 500
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		return
	var wanted := "Default"
	if FileAccess.file_exists(_marker):
		# ALSA enumerates every PCM on this call. Run it only to select a route.
		if _applied != "Default":
			return
		for device in AudioServer.get_output_device_list():
			if device.begins_with(DEVICE):
				wanted = device
	_apply(wanted)


# BlueALSA gives a headset to one program only. Call this before a game starts.
# The next poll after the game selects the headset again.
func release() -> void:
	_apply("Default")


func _apply(device: String) -> void:
	# Set a device one time. The engine goes back to Default if the open fails.
	if device != _applied:
		_applied = device
		AudioServer.output_device = device
