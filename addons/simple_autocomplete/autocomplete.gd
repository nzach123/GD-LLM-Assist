@tool
extends EditorPlugin

# --- CONFIG (Now uses ProjectSettings) ---
const SETTING_PREFIX = "addons/simple_autocomplete/"
const DEBUG = true

# Defaults
const DEFAULT_URL = "http://localhost:11434/api/generate"
const DEFAULT_MODEL = "qwen2.5-coder:1.5b"
const DEFAULT_DEBOUNCE = 0.4
const DEFAULT_MAX_LINES = 4
const DEFAULT_NUM_PREDICT = 128
const DEFAULT_TEMPERATURE = 0.1
const DEFAULT_NUM_CTX = 4096

# --- DOCK ---
const SettingsDockScript = preload("res://addons/simple_autocomplete/settings_dock.gd")
var settings_dock: Control

# --- VARS ---
var current_code_edit: CodeEdit
var overlay: PanelContainer  # Container with background
var overlay_label: Label
var timer: Timer
var http: HTTPRequest
var _current_base_indent: int = 0  # Track indent level for multi-line validation
var _was_truncated: bool = false

func _log(msg: String):
	if DEBUG:
		print("[SimpleAutocomplete] ", msg)

# --- SETTINGS HELPERS ---
func _init_settings():
	var settings = {
		"url": DEFAULT_URL,
		"model": DEFAULT_MODEL,
		"debounce": DEFAULT_DEBOUNCE,
		"max_lines": DEFAULT_MAX_LINES,
	}
	var added_new = false
	for key in settings.keys():
		var full_key = SETTING_PREFIX + key
		if not ProjectSettings.has_setting(full_key):
			ProjectSettings.set_setting(full_key, settings[key])
			ProjectSettings.set_initial_value(full_key, settings[key])
			added_new = true
			_log("Created setting: " + full_key)
	if added_new:
		ProjectSettings.save()

func _get_setting(key: String, default):
	var full_key = SETTING_PREFIX + key
	if ProjectSettings.has_setting(full_key):
		return ProjectSettings.get_setting(full_key)
	return default

func _enter_tree():
	_log("Plugin loading...")
	_init_settings()
	
	# Create and add settings dock
	settings_dock = SettingsDockScript.new()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, settings_dock)
	settings_dock.settings_changed.connect(_on_settings_changed)
	_log("Settings dock added")
	
	# Create overlay with dark background
	overlay = PanelContainer.new()
	overlay.top_level = true  # Escape parent clipping!
	
	# Dark semi-transparent background
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	overlay.add_theme_stylebox_override("panel", style)
	
	# Label inside
	overlay_label = Label.new()
	overlay_label.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6, 1.0))  # Bright green
	overlay.add_child(overlay_label)
	
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.hide()
	
	http = HTTPRequest.new()
	http.request_completed.connect(_on_ollama_reply)
	add_child(http)
	
	timer = Timer.new()
	timer.wait_time = _get_setting("debounce", DEFAULT_DEBOUNCE)
	timer.one_shot = true
	timer.timeout.connect(_request_completion)
	add_child(timer)
	
	var script_editor = EditorInterface.get_script_editor()
	if script_editor:
		script_editor.editor_script_changed.connect(_on_script_changed)
		_on_script_changed(script_editor.get_current_script())
		_log("Plugin loaded!")

func _exit_tree():
	if settings_dock and is_instance_valid(settings_dock):
		remove_control_from_docks(settings_dock)
		settings_dock.queue_free()
		_log("Settings dock removed")
	if overlay and is_instance_valid(overlay): 
		overlay.queue_free()
	if timer and is_instance_valid(timer): 
		timer.queue_free()
	if http and is_instance_valid(http): 
		http.queue_free()

func _on_settings_changed():
	# Update timer with new debounce value
	timer.wait_time = _get_setting("debounce", DEFAULT_DEBOUNCE)
	_log("Settings updated, debounce: " + str(timer.wait_time))

func _on_script_changed(_s):
	var script_editor = EditorInterface.get_script_editor()
	var current_editor = script_editor.get_current_editor()
	
	if current_code_edit and is_instance_valid(current_code_edit):
		if current_code_edit.text_changed.is_connected(_on_text_changed):
			current_code_edit.text_changed.disconnect(_on_text_changed)
			
	if current_editor:
		current_code_edit = current_editor.get_base_editor()
		if current_code_edit:
			current_code_edit.text_changed.connect(_on_text_changed)
			if overlay.get_parent(): 
				overlay.get_parent().remove_child(overlay)
			current_code_edit.add_child(overlay)
			_log("Attached to CodeEdit")

func _on_text_changed():
	overlay.hide()
	http.cancel_request()
	timer.start()

func _request_completion():
	if not current_code_edit or not is_instance_valid(current_code_edit): 
		return
	
	var code = current_code_edit.text
	var line_idx = current_code_edit.get_caret_line()
	var col_idx = current_code_edit.get_caret_column()
	var lines = code.split("\n")
	
	var start = max(0, line_idx - 30)
	var end = min(lines.size(), line_idx + 10)
	
	var current_line = lines[line_idx] if line_idx < lines.size() else ""
	var prefix_part = current_line.substr(0, col_idx)
	var suffix_part = current_line.substr(col_idx)
	
	# Store base indent for multi-line validation
	_current_base_indent = current_line.length() - current_line.strip_edges(true, false).length()
	
	var prefix = "\n".join(lines.slice(start, line_idx)) + "\n" + prefix_part
	var suffix = suffix_part + "\n" + "\n".join(lines.slice(line_idx + 1, end))
	var prompt = "<|fim_prefix|>" + prefix + "<|fim_suffix|>" + suffix + "<|fim_middle|>"
	
	var body = JSON.stringify({
		"model": _get_setting("model", DEFAULT_MODEL),
		"prompt": prompt,
		"raw": true,
		"stream": false,
		"options": {
			"temperature": _get_setting("temperature", DEFAULT_TEMPERATURE),
			"num_predict": DEFAULT_NUM_PREDICT,
			"num_ctx": _get_setting("num_ctx", DEFAULT_NUM_CTX),
			"stop": ["<|file_separator|>", "\n\n"]
		}
	})
	
	_log("Requesting...")
	http.request(_get_setting("url", DEFAULT_URL), ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _on_ollama_reply(_res, response_code, _headers, body):
	if response_code != 200: 
		_log("ERROR: " + str(response_code))
		return
	
	var json = JSON.parse_string(body.get_string_from_utf8())
	if not json or not "response" in json:
		return
	
	var text = json["response"]
	_log("Raw: '" + text.substr(0, 60).replace("\n", "\\n") + "'")
	
	text = _clean_completion(text)
	if text.strip_edges() == "": 
		return
	
	# Add truncation indicator if needed
	if _was_truncated:
		text += " ..."
	
	_log("Show: '" + text.replace("\n", "\\n") + "'")
	
	if not current_code_edit or not is_instance_valid(current_code_edit):
		return
	
	# Get position in global coordinates (since top_level = true)
	var caret_local = current_code_edit.get_caret_draw_pos()
	var caret_global = current_code_edit.get_global_transform() * caret_local
	
	# Get font to match
	var font = current_code_edit.get_theme_font("font")
	var font_size = current_code_edit.get_theme_font_size("font_size")
	
	overlay_label.add_theme_font_override("font", font)
	overlay_label.add_theme_font_size_override("font_size", font_size)
	overlay_label.text = text
	overlay.global_position = caret_global + Vector2(4, 2)
	overlay.show()

func _clean_completion(text: String) -> String:
	_was_truncated = false
	var max_lines = _get_setting("max_lines", DEFAULT_MAX_LINES)
	var lines = text.split("\n")
	var result = []
	
	for i in range(lines.size()):
		var line = lines[i]
		var stripped = line.strip_edges()
		
		# Skip markdown code fences
		if stripped.begins_with("```"):
			continue
		# Skip explanatory text (model hallucination)
		if stripped.begins_with("It ") or stripped.begins_with("This "):
			continue
		
		# Calculate this line's indent (tabs count as indent)
		var line_indent = line.length() - line.strip_edges(true, false).length()
		
		# For lines after the first, check indentation guard
		if result.size() > 0 and stripped != "":
			# If this line de-indents below our base, it might be the end of a block
			# Allow de-indent by one level (e.g., closing an if statement)
			if line_indent < _current_base_indent - 1:
				_was_truncated = true
				break
		
		if stripped != "":
			result.append(line)
		elif result.size() > 0:
			# Include empty lines within a block, but stop on double newline (should be handled by stop sequence)
			result.append(line)
		
		# Enforce max_lines limit
		if result.size() >= max_lines:
			_was_truncated = true
			break
	
	# Join lines and strip trailing whitespace from the block
	var completion = "\n".join(result).strip_edges(false, true)
	
	# --- Single-line quality filters (only apply if single line) ---
	if result.size() == 1:
		var single = completion.strip_edges()
		# Filter out unhelpful single-word completions
		var unhelpful = ["null", "true", "false", "pass", "self", "0", "1", "-1", "\"\"", "''", "[]", "{}"]
		if single in unhelpful:
			return ""
		
		# Filter out numeric literals (0.0, 1.5, etc.)
		if single.is_valid_float() or single.is_valid_int():
			return ""
		
		# Filter out partial variable names (start with lowercase but no = or ())
		if single.length() > 0:
			var first_char = single[0]
			if (first_char == "_" or (first_char >= "a" and first_char <= "z")):
				if not ("=" in single or "(" in single or "." in single):
					if single.length() < 12:
						return ""
		
		# Require at least some structure for short completions
		if single.length() < 4 and not "(" in single and not "." in single:
			return ""
	
	return completion

func _input(event):
	# Only process if overlay is showing
	if not overlay or not overlay.visible: 
		return
	
	if event is InputEventKey and event.pressed:
		_log("Key pressed: " + str(event.keycode) + " (TAB=" + str(KEY_TAB) + ")")
		
		if event.keycode == KEY_TAB:
			_log("TAB detected! Inserting: '" + overlay_label.text + "'")
			if current_code_edit and is_instance_valid(current_code_edit):
				current_code_edit.insert_text_at_caret(overlay_label.text)
			overlay.hide()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE:
			_log("ESC - hiding overlay")
			overlay.hide()
			get_viewport().set_input_as_handled()
		elif event.keycode != KEY_SHIFT and event.keycode != KEY_CTRL and event.keycode != KEY_ALT:
			# Any other typing key hides the overlay
			overlay.hide()
