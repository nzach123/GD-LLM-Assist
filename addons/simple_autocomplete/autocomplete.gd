@tool
extends EditorPlugin

# --- IMPORTS ---
const Constants = preload("res://addons/simple_autocomplete/constants.gd")

# --- CONFIG ---
const DEBUG = true

# Convenience aliases from Constants
var SETTING_PREFIX: String:
	get: return Constants.SETTING_PREFIX

# --- DOCK ---
const SettingsDockScript = preload("res://addons/simple_autocomplete/settings_dock.gd")
var settings_dock: Control

# --- VARS ---
var current_code_edit: CodeEdit
var overlay: PanelContainer  # Container with background
var overlay_label: Label
var timer: Timer
var request_manager: StreamRequestManager
var _current_base_indent: int = 0  # Track indent level for multi-line validation
var _was_truncated: bool = false
var _accumulated_text: String = ""

# --- INNER CLASS: SafetyValidator ---
class SafetyValidator:
	# Common base classes to check methods against
	const CHECK_CLASSES = ["Object", "Node", "Node2D", "Node3D", "Control", "CanvasItem", "Resource"]
	
	static func is_text_safe(text: String) -> bool:
		# 1. Pythonisms
		if "def " in text: return false
		if "import " in text and not "resource" in text: return false
		
		# 2. Check deprecated patterns from constants
		if Constants.is_deprecated_pattern(text):
			return false
		
		return true

	static func check_method_validity(text: String) -> bool:
		# Extract method calls that look like Godot API calls
		var regex = RegEx.new()
		# Match: self.method( or .method( patterns (lowercase methods typical of Godot API)
		regex.compile("(?:self|\\$[\\w/]+|get_node\\([^)]+\\))\\.([a-z_][a-z0-9_]*)\\(")
		var matches = regex.search_all(text)
		
		for m in matches:
			var method_name = m.get_string(1)
			
			# Skip common user-defined patterns (signals, private methods)
			if method_name.begins_with("_") and not method_name.begins_with("_on_"):
				continue  # Likely user-defined
			if method_name.begins_with("on_"):
				continue  # Likely user-defined signal handler
			
			# Check if method exists in any common base class
			var found = false
			for cls_name in CHECK_CLASSES:
				if ClassDB.class_has_method(cls_name, method_name):
					found = true
					break
			
			# If it looks like a standard API call but isn't found, flag it
			# Only flag methods that look like Godot naming convention (snake_case, common prefixes)
			if not found:
				var godot_prefixes = ["get_", "set_", "is_", "has_", "can_", "add_", "remove_", "emit_"]
				for prefix in godot_prefixes:
					if method_name.begins_with(prefix):
						# This looks like a Godot method but doesn't exist - likely hallucinated
						return false
		
		return true

# --- INNER CLASS: ContextManager ---
class ContextManager:
	static func get_context(root: Node) -> String:
		var parts = []

		# Scene Tree
		var tree_str = _get_flattened_scene_tree(root)
		if tree_str:
			parts.append("# Scene Tree:\n# " + tree_str.replace("\n", "\n# "))

		# Global Classes
		var class_str = _get_global_classes()
		if class_str:
			parts.append("# Global Classes: " + class_str)

		if parts.is_empty():
			return ""

		return "# Context:\n" + "\n".join(parts) + "\n\n"

	static func _get_flattened_scene_tree(root: Node) -> String:
		if not root:
			return ""

		var lines = []
		var stack = [{"node": root, "path": root.name}]
		var count = 0
		var MAX_NODES = 50

		while stack.size() > 0:
			var item = stack.pop_back()
			var node = item["node"]
			var path = item["path"]

			var type_name = node.get_class()
			var script = node.get_script() as Script
			if script:
				var global_name = script.get_global_name()
				if global_name != "":
					type_name = global_name

			lines.append(path + " (" + type_name + ")")

			count += 1
			if count >= MAX_NODES:
				lines.append("... (truncated)")
				break

			var children = node.get_children()
			for i in range(children.size() - 1, -1, -1):
				var child = children[i]
				stack.push_back({"node": child, "path": path + "/" + child.name})

		return "\n".join(lines)

	static func _get_global_classes() -> String:
		var classes = ProjectSettings.get_global_class_list()
		if classes.is_empty():
			return ""

		var names = []
		for c in classes:
			names.append(c["class"])

		names.sort()
		if names.size() > 50:
			names = names.slice(0, 50)
			names.append("...")

		return ", ".join(names)

# --- INNER CLASS: StreamRequestManager ---
class StreamRequestManager:
	extends RefCounted

	signal chunk_received(text: String)
	signal finished()
	signal error(msg: String)

	enum State { IDLE, CONNECTING, REQUESTING, STREAMING }

	var _state: State = State.IDLE
	var _client: HTTPClient
	var _host: String
	var _port: int
	var _endpoint: String
	var _method: int
	var _headers: PackedStringArray
	var _body: String
	var _buffer: String = ""
	var _timeout_sec: float = Constants.DEFAULT_TIMEOUT
	var _elapsed_time: float = 0.0

	func _init():
		_client = HTTPClient.new()

	func request(url: String, headers: PackedStringArray, method: int, body: String):
		cancel()
		
		# Robust URL parsing with regex
		var url_regex = RegEx.new()
		# Matches: http(s)://host(:port)/path(?query)
		url_regex.compile("^(https?)://([^/:]+):?(\\d*)(/.*)$")
		var result = url_regex.search(url)
		
		if not result:
			error.emit("Invalid URL format: " + url)
			return
		
		var proto = result.get_string(1)  # "http" or "https"
		_host = result.get_string(2)
		var port_str = result.get_string(3)
		_endpoint = result.get_string(4) if result.get_string(4) else "/"
		
		# Parse port
		if port_str != "":
			_port = port_str.to_int()
		else:
			_port = 443 if proto == "https" else 80

		_headers = headers
		_method = method
		_body = body
		_buffer = ""
		_elapsed_time = 0.0

		# For HTTPS, pass TLSOptions; for HTTP, pass -1 for port auto-detection
		var tls_options = TLSOptions.client() if proto == "https" else null
		var err = _client.connect_to_host(_host, _port, tls_options)
		if err != OK:
			error.emit("Connection failed to " + _host + ":" + str(_port) + " - Error: " + str(err))
			_state = State.IDLE
			return

		_state = State.CONNECTING

	func cancel():
		_client.close()
		_state = State.IDLE
		_buffer = ""
		_elapsed_time = 0.0

	func is_busy() -> bool:
		return _state != State.IDLE
	
	func poll_with_delta(delta: float):
		if _state == State.IDLE:
			return
		
		# Track timeout
		_elapsed_time += delta
		if _elapsed_time > _timeout_sec:
			error.emit("Request timed out after " + str(_timeout_sec) + " seconds")
			cancel()
			return
		
		_client.poll()
		var status = _client.get_status()

		if _state == State.CONNECTING:
			if status == HTTPClient.STATUS_CONNECTED:
				_state = State.REQUESTING
				var err = _client.request(_method, _endpoint, _headers, _body)
				if err != OK:
					error.emit("Request failed: " + str(err))
					cancel()
			elif status == HTTPClient.STATUS_CANT_CONNECT or status == HTTPClient.STATUS_CONNECTION_ERROR:
				error.emit("Connection error to " + _host)
				cancel()

		elif _state == State.REQUESTING:
			if status == HTTPClient.STATUS_BODY:
				_state = State.STREAMING
				_elapsed_time = 0.0  # Reset timeout for streaming phase
			elif status == HTTPClient.STATUS_CANT_CONNECT or status == HTTPClient.STATUS_CONNECTION_ERROR:
				error.emit("Request error")
				cancel()

		elif _state == State.STREAMING:
			if status == HTTPClient.STATUS_BODY:
				var chunk = _client.read_response_body_chunk()
				if chunk.size() > 0:
					var text = chunk.get_string_from_utf8()
					_process_chunk_text(text)
					_elapsed_time = 0.0  # Reset timeout on each chunk
			elif status == HTTPClient.STATUS_DISCONNECTED or status == HTTPClient.STATUS_CONNECTED:
				# If we go back to CONNECTED, it means the request finished but connection is kept alive
				finished.emit()
				_state = State.IDLE

	func _process_chunk_text(text: String):
		_buffer += text
		while "\n" in _buffer:
			var split = _buffer.split("\n", true, 1)
			var line = split[0]
			_buffer = split[1]
			if line.strip_edges() != "":
				chunk_received.emit(line)

func _log(msg: String):
	if DEBUG:
		print("[SimpleAutocomplete] ", msg)

# --- SETTINGS HELPERS ---
func _init_settings():
	var settings = {
		"url": Constants.DEFAULT_URL,
		"model": Constants.DEFAULT_MODEL,
		"debounce": Constants.DEFAULT_DEBOUNCE,
		"max_lines": Constants.DEFAULT_MAX_LINES,
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
	
	request_manager = StreamRequestManager.new()
	request_manager.chunk_received.connect(_on_ollama_chunk)
	request_manager.finished.connect(_on_ollama_finished)
	request_manager.error.connect(func(msg): _log("Error: " + msg))
	
	timer = Timer.new()
	timer.wait_time = _get_setting("debounce", Constants.DEFAULT_DEBOUNCE)
	timer.one_shot = true
	timer.timeout.connect(_request_completion_auto)
	add_child(timer)
	
	var script_editor = EditorInterface.get_script_editor()
	if script_editor:
		script_editor.editor_script_changed.connect(_on_script_changed)
		_on_script_changed(script_editor.get_current_script())
		_log("Plugin loaded!")

func _process(delta):
	if request_manager:
		request_manager.poll_with_delta(delta)

func _exit_tree():
	if settings_dock and is_instance_valid(settings_dock):
		remove_control_from_docks(settings_dock)
		settings_dock.queue_free()
		_log("Settings dock removed")
	if overlay and is_instance_valid(overlay): 
		overlay.queue_free()
	if timer and is_instance_valid(timer): 
		timer.queue_free()
	if request_manager:
		request_manager.cancel()
		request_manager = null

func _on_settings_changed():
	# Update timer with new debounce value
	timer.wait_time = _get_setting("debounce", Constants.DEFAULT_DEBOUNCE)
	_log("Settings updated, debounce: " + str(timer.wait_time))

func _on_script_changed(_s):
	var script_editor = EditorInterface.get_script_editor()
	var current_editor = script_editor.get_current_editor()
	
	if current_code_edit and is_instance_valid(current_code_edit):
		if current_code_edit.text_changed.is_connected(_on_text_changed):
			current_code_edit.text_changed.disconnect(_on_text_changed)
		if current_code_edit.caret_changed.is_connected(_on_caret_changed):
			current_code_edit.caret_changed.disconnect(_on_caret_changed)
			
	if current_editor:
		current_code_edit = current_editor.get_base_editor()
		if current_code_edit:
			current_code_edit.text_changed.connect(_on_text_changed)
			current_code_edit.caret_changed.connect(_on_caret_changed)
			if overlay.get_parent(): 
				overlay.get_parent().remove_child(overlay)
			current_code_edit.add_child(overlay)
			_log("Attached to CodeEdit")

func _on_text_changed():
	overlay.hide()
	request_manager.cancel()
	_accumulated_text = ""
	timer.start()

func _on_caret_changed():
	# Hide overlay when moving cursor without typing
	if overlay.visible:
		overlay.hide()
		request_manager.cancel()
		_accumulated_text = ""

func _request_completion_auto():
	# Auto-trigger check: don't trigger if menu is visible
	if current_code_edit and current_code_edit.is_menu_visible():
		return
	_trigger_request()

func _trigger_request():
	if not current_code_edit or not is_instance_valid(current_code_edit): 
		return
	
	_accumulated_text = "" # Reset

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

	# Context Injection
	var context = ContextManager.get_context(EditorInterface.get_edited_scene_root())
	
	# Get model name and determine FIM format
	var model_name = _get_setting("model", Constants.DEFAULT_MODEL)
	var fim_format = Constants.get_fim_format_for_model(model_name)
	var fim_prefix = fim_format[0]
	var fim_suffix = fim_format[1]
	var fim_middle = fim_format[2]

	# Build prompt with dynamic FIM tokens
	var prompt = Constants.SYSTEM_PROMPT + "\n" + fim_prefix + context + prefix + fim_suffix + suffix + fim_middle
	
	var body = JSON.stringify({
		"model": model_name,
		"prompt": prompt,
		"raw": true,
		"stream": true, # Enable streaming
		"options": {
			"temperature": _get_setting("temperature", Constants.DEFAULT_TEMPERATURE),
			"num_predict": Constants.DEFAULT_NUM_PREDICT,
			"num_ctx": _get_setting("num_ctx", Constants.DEFAULT_NUM_CTX),
			"stop": ["<|file_separator|>", "\n\n", "\nfunc ", "\nclass ", "\n#", "```"]
		}
	})
	
	_log("Requesting (Stream) with model: " + model_name + ", FIM format: " + fim_prefix.substr(0, 10) + "...")
	request_manager.request(_get_setting("url", Constants.DEFAULT_URL), ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _on_ollama_finished():
	if _accumulated_text != "":
		# Final Safety Check (ClassDB)
		if not SafetyValidator.check_method_validity(_accumulated_text):
			_log("Final Safety Check Failed. Hiding overlay.")
			overlay.hide()
			return

func _on_ollama_chunk(json_line: String):
	var json = JSON.parse_string(json_line)
	if not json or not "response" in json:
		return
	
	var text_chunk = json["response"]
	_accumulated_text += text_chunk

	# --- Safety Check ---
	if not SafetyValidator.is_text_safe(_accumulated_text):
		_log("Safety Violation detected. Aborting stream.")
		request_manager.cancel()
		overlay.hide()
		return

	# --- Streaming Clean & Show ---
	var clean_text = _clean_completion(_accumulated_text)
	
	if clean_text.strip_edges() == "":
		return # Wait for more tokens
	
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
	overlay_label.text = clean_text
	overlay.global_position = caret_global + Vector2(4, 2)
	overlay.show()

func _clean_completion(text: String) -> String:
	_was_truncated = false
	var max_lines = _get_setting("max_lines", Constants.DEFAULT_MAX_LINES)
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
	# Only apply strict filters if we have a "finished" or "significant" amount of text,
	# but for streaming we want to show it as it comes.
	# However, if the accumulating text currently looks like "null", we don't want to show it.

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
		# For streaming, we might be mid-typing "var x = 1", so "var" is fine.
		# But "x" alone is not.
		# This filter is tricky for streaming. We might hide valid partials.
		# Let's relax this for streaming or check length.
		# If we are streaming, we might want to be more permissive, but the user requirement
		# is to avoid "garbage".
		# I'll keep it but be aware it might delay display of short variables.

		if single.length() > 0:
			var first_char = single[0]
			if (first_char == "_" or (first_char >= "a" and first_char <= "z")):
				if not ("=" in single or "(" in single or "." in single):
					if single.length() < 12:
						# If it's short and simple, hide it until it becomes more complex?
						# Or maybe allow it if it's longer than X?
						return ""
		
		# Require at least some structure for short completions
		if single.length() < 4 and not "(" in single and not "." in single:
			return ""
	
	return completion

func _input(event):
	# Handle manual trigger
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_SPACE and event.ctrl_pressed:
			if current_code_edit and is_instance_valid(current_code_edit) and current_code_edit.has_focus():
				# Don't hijack if native menu is already doing something
				if not current_code_edit.is_menu_visible():
					_log("Ctrl+Space detected - Force Trigger")
					if timer:
						timer.stop()
					_trigger_request()
					get_viewport().set_input_as_handled()
					return

	# Only process further input if overlay is showing
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
		elif event.keycode == KEY_RIGHT and event.ctrl_pressed:
			_log("Ctrl+Right detected - Partial Accept")
			_handle_partial_accept()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE:
			_log("ESC - hiding overlay")
			overlay.hide()
			get_viewport().set_input_as_handled()
		elif event.keycode != KEY_SHIFT and event.keycode != KEY_CTRL and event.keycode != KEY_ALT:
			# Any other typing key hides the overlay
			overlay.hide()

func _handle_partial_accept():
	if not current_code_edit or not is_instance_valid(current_code_edit):
		return

	var text = overlay_label.text
	if text.is_empty():
		return

	var regex = RegEx.new()
	# Capture first word (alphanumeric+underscore) OR first sequence of non-word chars OR whitespace
	regex.compile("^(\\w+|\\s+|\\W)")
	var result = regex.search(text)

	if result:
		var token = result.get_string()
		current_code_edit.insert_text_at_caret(token)

		# Update overlay text by removing the inserted token
		var remaining = text.substr(token.length())
		overlay_label.text = remaining

		# If nothing left, hide
		if remaining.is_empty():
			overlay.hide()
		else:
			# Update position to follow caret
			# We need to wait a frame or force update for caret position to update?
			# insert_text_at_caret updates caret immediately.
			var caret_local = current_code_edit.get_caret_draw_pos()
			var caret_global = current_code_edit.get_global_transform() * caret_local
			overlay.global_position = caret_global + Vector2(4, 2)
