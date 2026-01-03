@tool
extends SceneTree

## Simple Autocomplete Addon - Verification Tests
## Run via: godot --headless --script addons/simple_autocomplete/tests/test_autocomplete.gd

func _init():
	print("\n=== Simple Autocomplete Addon Tests ===\n")
	
	var all_passed = true
	
	# Test 1: Plugin file exists
	all_passed = _test("Plugin config exists", func():
		return FileAccess.file_exists("res://addons/simple_autocomplete/plugin.cfg")
	) and all_passed
	
	# Test 2: Script file exists
	all_passed = _test("Autocomplete script exists", func():
		return FileAccess.file_exists("res://addons/simple_autocomplete/autocomplete.gd")
	) and all_passed
	
	# Test 3: Script can be loaded
	all_passed = _test("Script loads without errors", func():
		var script = load("res://addons/simple_autocomplete/autocomplete.gd")
		return script != null
	) and all_passed
	
	# Test 4: Constants are defined
	all_passed = _test("Constants are properly defined", func():
		var script = load("res://addons/simple_autocomplete/autocomplete.gd")
		var instance = script.new()
		var has_debounce = "DEBOUNCE_TIME" in instance
		var has_url = "OLLAMA_URL" in instance
		var has_model = "MODEL" in instance
		instance.free()
		return has_debounce and has_url and has_model
	) and all_passed
	
	# Test 5: Ollama connectivity
	all_passed = _test("Ollama is reachable", func():
		var http = HTTPRequest.new()
		add_root(http)
		var result = http.request("http://localhost:11434/api/tags", [], HTTPClient.METHOD_GET)
		http.queue_free()
		return result == OK
	) and all_passed
	
	# Test 6: FIM prompt format
	all_passed = _test("FIM prompt format is correct", func():
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
	var result = test_func.call()
	if result:
		print("  ✅ PASS: " + name)
	else:
		print("  ❌ FAIL: " + name)
	return result
