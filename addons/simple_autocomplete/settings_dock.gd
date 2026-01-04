@tool
extends Control
class_name SettingsDock

## Settings Dock for Simple Autocomplete
## Provides a user-friendly UI for configuring Ollama settings

signal settings_changed

# --- IMPORTS ---
const Constants = preload("res://addons/simple_autocomplete/constants.gd")

# --- CONSTANTS ---
# Use shared constants from Constants module
var SETTING_PREFIX: String:
	get: return Constants.SETTING_PREFIX

const CONTEXT_OPTIONS = {
	"2K (2048)": 2048,
	"4K (4096)": 4096,
	"8K (8192)": 8192,
	"16K (16384)": 16384,
	"32K (32768)": 32768
}

# --- UI REFERENCES ---
var url_edit: LineEdit
var test_button: Button
var model_option: OptionButton
var refresh_button: Button
var status_icon: TextureRect
var status_label: Label

var max_lines_spin: SpinBox
var temp_slider: HSlider
var temp_label: Label
var context_option: OptionButton
var debounce_spin: SpinBox

# --- STATE ---
var http_test: HTTPRequest
var http_models: HTTPRequest
var _save_timer: Timer  # Debounced save

func _ready():
	name = "Autocomplete Settings"
	custom_minimum_size = Vector2(250, 0)
	
	_build_ui()
	_setup_http()
	_load_settings()

func _build_ui():
	var main_vbox = VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(main_vbox)
	
	# === HEADER ===
	var header = Label.new()
	header.text = "⚙️ Ollama Connection"
	header.add_theme_font_size_override("font_size", 16)
	main_vbox.add_child(header)
	
	main_vbox.add_child(_create_separator())
	
	# === CONNECTION SECTION ===
	# URL Row
	var url_row = HBoxContainer.new()
	main_vbox.add_child(url_row)
	
	var url_label = Label.new()
	url_label.text = "URL"
	url_label.custom_minimum_size.x = 70
	url_row.add_child(url_label)
	
	url_edit = LineEdit.new()
	url_edit.placeholder_text = "http://localhost:11434/api/generate"
	url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	url_edit.focus_exited.connect(_on_setting_changed)
	url_row.add_child(url_edit)
	
	test_button = Button.new()
	test_button.text = "Test"
	test_button.pressed.connect(_on_test_connection)
	url_row.add_child(test_button)
	
	# Status Row
	var status_row = HBoxContainer.new()
	main_vbox.add_child(status_row)
	
	status_icon = TextureRect.new()
	status_icon.custom_minimum_size = Vector2(16, 16)
	status_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	status_row.add_child(status_icon)
	
	status_label = Label.new()
	status_label.text = "Not tested"
	status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	status_row.add_child(status_label)
	
	# Model Row
	var model_row = HBoxContainer.new()
	main_vbox.add_child(model_row)
	
	var model_label = Label.new()
	model_label.text = "Model"
	model_label.custom_minimum_size.x = 70
	model_row.add_child(model_label)
	
	model_option = OptionButton.new()
	model_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	model_option.item_selected.connect(_on_model_selected)
	model_row.add_child(model_option)
	
	refresh_button = Button.new()
	refresh_button.text = "↻"
	refresh_button.tooltip_text = "Refresh models from Ollama"
	refresh_button.pressed.connect(_on_refresh_models)
	model_row.add_child(refresh_button)
	
	main_vbox.add_child(_create_separator())
	
	# === GENERATION SECTION ===
	var gen_header = Label.new()
	gen_header.text = "🎛️ Generation"
	gen_header.add_theme_font_size_override("font_size", 14)
	main_vbox.add_child(gen_header)
	
	# Max Lines Row
	var lines_row = HBoxContainer.new()
	main_vbox.add_child(lines_row)
	
	var lines_label = Label.new()
	lines_label.text = "Max Lines"
	lines_label.custom_minimum_size.x = 100
	lines_row.add_child(lines_label)
	
	max_lines_spin = SpinBox.new()
	max_lines_spin.min_value = 1
	max_lines_spin.max_value = 20
	max_lines_spin.value = 4
	max_lines_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	max_lines_spin.get_line_edit().focus_exited.connect(_on_setting_changed)
	lines_row.add_child(max_lines_spin)
	
	# Temperature Row (HSlider + Label)
	var temp_row = HBoxContainer.new()
	main_vbox.add_child(temp_row)
	
	var temp_text = Label.new()
	temp_text.text = "Temperature"
	temp_text.custom_minimum_size.x = 100
	temp_row.add_child(temp_text)
	
	temp_slider = HSlider.new()
	temp_slider.min_value = 0.0
	temp_slider.max_value = 1.0
	temp_slider.step = 0.05
	temp_slider.value = 0.1
	temp_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	temp_slider.drag_ended.connect(_on_slider_drag_ended)
	temp_slider.value_changed.connect(_on_temp_value_changed)
	temp_row.add_child(temp_slider)
	
	temp_label = Label.new()
	temp_label.text = "0.10"
	temp_label.custom_minimum_size.x = 40
	temp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	temp_row.add_child(temp_label)
	
	# Context Window Row
	var ctx_row = HBoxContainer.new()
	main_vbox.add_child(ctx_row)
	
	var ctx_label = Label.new()
	ctx_label.text = "Context"
	ctx_label.custom_minimum_size.x = 100
	ctx_row.add_child(ctx_label)
	
	context_option = OptionButton.new()
	context_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for label in CONTEXT_OPTIONS.keys():
		context_option.add_item(label)
	context_option.select(1)  # Default to 4K
	context_option.item_selected.connect(_on_context_selected)
	ctx_row.add_child(context_option)
	
	main_vbox.add_child(_create_separator())
	
	# === BEHAVIOR SECTION ===
	var beh_header = Label.new()
	beh_header.text = "⏱️ Behavior"
	beh_header.add_theme_font_size_override("font_size", 14)
	main_vbox.add_child(beh_header)
	
	# Debounce Row
	var debounce_row = HBoxContainer.new()
	main_vbox.add_child(debounce_row)
	
	var debounce_label = Label.new()
	debounce_label.text = "Debounce (s)"
	debounce_label.custom_minimum_size.x = 100
	debounce_row.add_child(debounce_label)
	
	debounce_spin = SpinBox.new()
	debounce_spin.min_value = 0.1
	debounce_spin.max_value = 2.0
	debounce_spin.step = 0.1
	debounce_spin.value = 0.4
	debounce_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	debounce_spin.get_line_edit().focus_exited.connect(_on_setting_changed)
	debounce_row.add_child(debounce_spin)

func _create_separator() -> HSeparator:
	var sep = HSeparator.new()
	sep.add_theme_constant_override("separation", 10)
	return sep

func _setup_http():
	http_test = HTTPRequest.new()
	http_test.request_completed.connect(_on_test_completed)
	add_child(http_test)
	
	http_models = HTTPRequest.new()
	http_models.request_completed.connect(_on_models_received)
	add_child(http_models)
	
	# Debounced save timer
	_save_timer = Timer.new()
	_save_timer.wait_time = 0.5
	_save_timer.one_shot = true
	_save_timer.timeout.connect(_do_save_settings)
	add_child(_save_timer)

func _load_settings():
	# Load URL
	if ProjectSettings.has_setting(SETTING_PREFIX + "url"):
		url_edit.text = ProjectSettings.get_setting(SETTING_PREFIX + "url")
	else:
		url_edit.text = "http://localhost:11434/api/generate"
	
	# Load Model (will be set when models are fetched)
	var saved_model = ""
	if ProjectSettings.has_setting(SETTING_PREFIX + "model"):
		saved_model = ProjectSettings.get_setting(SETTING_PREFIX + "model")
	
	# Load Max Lines
	if ProjectSettings.has_setting(SETTING_PREFIX + "max_lines"):
		max_lines_spin.value = ProjectSettings.get_setting(SETTING_PREFIX + "max_lines")
	
	# Load Temperature
	if ProjectSettings.has_setting(SETTING_PREFIX + "temperature"):
		temp_slider.value = ProjectSettings.get_setting(SETTING_PREFIX + "temperature")
		temp_label.text = "%.2f" % temp_slider.value
	
	# Load Context
	if ProjectSettings.has_setting(SETTING_PREFIX + "num_ctx"):
		var ctx_val = ProjectSettings.get_setting(SETTING_PREFIX + "num_ctx")
		var idx = 0
		for label in CONTEXT_OPTIONS.keys():
			if CONTEXT_OPTIONS[label] == ctx_val:
				context_option.select(idx)
				break
			idx += 1
	
	# Load Debounce
	if ProjectSettings.has_setting(SETTING_PREFIX + "debounce"):
		debounce_spin.value = ProjectSettings.get_setting(SETTING_PREFIX + "debounce")
	
	# Auto-fetch models on load
	call_deferred("_on_refresh_models")

# --- EVENT HANDLERS ---

func _on_setting_changed():
	_save_timer.start()
	settings_changed.emit()

func _on_slider_drag_ended(_value_changed: bool):
	_save_timer.start()
	settings_changed.emit()

func _on_temp_value_changed(value: float):
	temp_label.text = "%.2f" % value

func _on_model_selected(_idx: int):
	_save_timer.start()
	settings_changed.emit()

func _on_context_selected(_idx: int):
	_save_timer.start()
	settings_changed.emit()

func _on_test_connection():
	_set_status("testing", "Testing...")
	test_button.disabled = true
	
	# Extract base URL for /api/tags endpoint
	var base_url = url_edit.text.replace("/api/generate", "").rstrip("/")
	var tags_url = base_url + "/api/tags"
	
	var err = http_test.request(tags_url, [], HTTPClient.METHOD_GET)
	if err != OK:
		_set_status("error", "Request failed: " + str(err))
		test_button.disabled = false

func _on_test_completed(_result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray):
	test_button.disabled = false
	
	if response_code == 200:
		_set_status("ok", "Connected!")
	elif response_code == 0:
		_set_status("error", "Connection failed - is Ollama running?")
	else:
		_set_status("error", "HTTP " + str(response_code))

func _on_refresh_models():
	refresh_button.disabled = true
	model_option.clear()
	model_option.add_item("Loading...")
	
	# Extract base URL for /api/tags endpoint
	var base_url = url_edit.text.replace("/api/generate", "").rstrip("/")
	var tags_url = base_url + "/api/tags"
	
	var err = http_models.request(tags_url, [], HTTPClient.METHOD_GET)
	if err != OK:
		model_option.clear()
		model_option.add_item("⚠️ Failed to fetch")
		refresh_button.disabled = false
		_set_status("error", "Request error: " + str(err))

func _on_models_received(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
	refresh_button.disabled = false
	model_option.clear()
	
	if response_code != 200:
		model_option.add_item("⚠️ Connection failed")
		_set_status("error", "HTTP " + str(response_code))
		return
	
	var json = JSON.parse_string(body.get_string_from_utf8())
	if json == null or not "models" in json:
		model_option.add_item("⚠️ Invalid response")
		_set_status("error", "Invalid JSON response")
		return
	
	var models = json["models"]
	if models.size() == 0:
		model_option.add_item("No models found")
		return
	
	# Get saved model to restore selection
	var saved_model = ""
	if ProjectSettings.has_setting(SETTING_PREFIX + "model"):
		saved_model = ProjectSettings.get_setting(SETTING_PREFIX + "model")
	
	var selected_idx = 0
	for i in range(models.size()):
		var model_name = models[i]["name"]
		model_option.add_item(model_name)
		if model_name == saved_model:
			selected_idx = i
	
	model_option.select(selected_idx)
	_set_status("ok", "Found " + str(models.size()) + " models")

func _set_status(type: String, message: String):
	status_label.text = message
	
	match type:
		"ok":
			status_label.add_theme_color_override("font_color", Color(0.4, 0.9, 0.4))
		"error":
			status_label.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
		"testing":
			status_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.4))
		_:
			status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))

func _do_save_settings():
	# Save all settings to ProjectSettings
	ProjectSettings.set_setting(SETTING_PREFIX + "url", url_edit.text)
	
	if model_option.selected >= 0 and model_option.item_count > 0:
		var model_text = model_option.get_item_text(model_option.selected)
		if not model_text.begins_with("⚠️") and model_text != "Loading..." and model_text != "No models found":
			ProjectSettings.set_setting(SETTING_PREFIX + "model", model_text)
	
	ProjectSettings.set_setting(SETTING_PREFIX + "max_lines", int(max_lines_spin.value))
	ProjectSettings.set_setting(SETTING_PREFIX + "temperature", temp_slider.value)
	
	var ctx_label = context_option.get_item_text(context_option.selected)
	if ctx_label in CONTEXT_OPTIONS:
		ProjectSettings.set_setting(SETTING_PREFIX + "num_ctx", CONTEXT_OPTIONS[ctx_label])
	
	ProjectSettings.set_setting(SETTING_PREFIX + "debounce", debounce_spin.value)
	
	# Disk-heavy operation - only done after debounce
	ProjectSettings.save()
	print("[SettingsDock] Settings saved")
