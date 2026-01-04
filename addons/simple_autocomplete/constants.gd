@tool
class_name AutocompleteConstants
extends RefCounted

## Shared constants for the Simple Autocomplete addon
## Single source of truth for settings keys, defaults, and model configurations

# --- SETTINGS ---
const SETTING_PREFIX = "addons/simple_autocomplete/"

# --- DEFAULTS ---
const DEFAULT_URL = "http://localhost:11434/api/generate"
const DEFAULT_MODEL = "qwen2.5-coder:1.5b"
const DEFAULT_DEBOUNCE = 0.4
const DEFAULT_MAX_LINES = 4
const DEFAULT_NUM_PREDICT = 128
const DEFAULT_TEMPERATURE = 0.1
const DEFAULT_NUM_CTX = 4096
const DEFAULT_TIMEOUT = 30.0  # seconds

# --- SYSTEM PROMPT ---
const SYSTEM_PROMPT = "You are a Godot 4.5 GDScript expert. Prioritize typed GDScript, signal-based architecture, and composition. Output only the code completion."

# --- FIM (Fill-in-the-Middle) TOKEN FORMATS ---
# Different model families use different FIM token formats
# Format: [prefix_token, suffix_token, middle_token]
const FIM_FORMATS = {
	"qwen": ["<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>"],
	"deepseek": ["<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>"],
	"codellama": ["<PRE> ", " <SUF>", " <MID>"],
	"starcoder": ["<fim_prefix>", "<fim_suffix>", "<fim_middle>"],
	"codegemma": ["<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>"],
}

const DEFAULT_FIM_FORMAT = ["<|fim_prefix|>", "<|fim_suffix|>", "<|fim_middle|>"]

# --- KNOWN GODOT 3 / DEPRECATED METHODS ---
# Used by SafetyValidator to reject hallucinated legacy API calls
const DEPRECATED_METHODS = [
	"set_fixed_process",
	"get_tree().get_root()",
	"set_pos", "get_pos",  # Godot 3.x position methods
	"set_rot", "get_rot",  # Godot 3.x rotation methods
	"set_scale", "get_scale",  # These exist but often confused with deprecated patterns
]

# --- HELPER FUNCTIONS ---

## Get the FIM format for a given model name
## Returns [prefix_token, suffix_token, middle_token]
static func get_fim_format_for_model(model_name: String) -> Array:
	var lower_model = model_name.to_lower()
	
	for key in FIM_FORMATS.keys():
		if key in lower_model:
			return FIM_FORMATS[key]
	
	# Default to Qwen format (most common for code models)
	return DEFAULT_FIM_FORMAT

## Check if a method name appears to be deprecated/legacy
static func is_deprecated_pattern(text: String) -> bool:
	for pattern in DEPRECATED_METHODS:
		if pattern in text:
			return true
	return false
