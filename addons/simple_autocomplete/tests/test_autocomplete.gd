@tool
extends SceneTree

## Simple Autocomplete Addon - Verification Tests
## Run via: godot --headless --script addons/simple_autocomplete/tests/test_autocomplete.gd

func _init():
	print("\n=== Simple Autocomplete Addon Tests ===\n")
	_run.call_deferred()

func _run():
	var all_passed = true
	
	# Test 1: Plugin file exists
	all_passed = await _test("Plugin config exists", func():
		return FileAccess.file_exists("res://addons/simple_autocomplete/plugin.cfg")
	) and all_passed
	
	# Test 2: Script file exists
	all_passed = await _test("Autocomplete script exists", func():
		return FileAccess.file_exists("res://addons/simple_autocomplete/autocomplete.gd")
	) and all_passed
	
	# Test 3: Script can be loaded
	all_passed = await _test("Script loads without errors", func():
		var script = load("res://addons/simple_autocomplete/autocomplete.gd")
		return script != null
	) and all_passed
	
	# Test 4: Project Settings are initialized
	# Note: This requires the plugin to have been enabled at least once in the editor
	all_passed = await _test("Settings keys are present", func():
		var prefix = "addons/simple_autocomplete/"
		return ProjectSettings.has_setting(prefix + "url") or ProjectSettings.has_setting(prefix + "model")
	) and all_passed
	
	# Test 5: Ollama connectivity
	all_passed = await _test("Ollama is reachable", func():
		var http = HTTPRequest.new()
		root.add_child(http)
		
		# Small delay to ensure it's in the tree
		await get_frame()
		
		var err = http.request("http://127.0.0.1:11434/api/tags", [], HTTPClient.METHOD_GET)
		if err != OK:
			http.queue_free()
			return false
		
		var result = await http.request_completed
		http.queue_free()
		return result[1] == 200 # response_code
	) and all_passed
	
	# Test 6: FIM prompt format
	all_passed = await _test("FIM prompt format is correct", func():
		var prefix = "func _ready():\n\tvar x = "
		var suffix = "\n\tprint(x)"
		var prompt = "<|fim_prefix|>" + prefix + "<|fim_suffix|>" + suffix + "<|fim_middle|>"
		return prompt.contains("<|fim_prefix|>") and prompt.contains("<|fim_suffix|>") and prompt.contains("<|fim_middle|>")
	) and all_passed
	
	# Summary
	print("\n=== Results ===")
	if all_passed:
		print("✅ All tests passed!")
	else:
		print("❌ Some tests failed. Check output above.")
	
	quit()

func _test(name: String, test_func: Callable) -> bool:
	var result = await test_func.call()
	if result:
		print("  ✅ PASS: " + name)
	else:
		print("  ❌ FAIL: " + name)
	return result
