@tool
extends SceneTree

func _init():
	_run.call_deferred()

func _run():
	print("Minimal HTTP Test (Deferred)")
	var http = HTTPRequest.new()
	root.add_child(http)
	
	# Small delay to ensure it's in the tree
	await get_frame()
	
	var err = http.request("http://127.0.0.1:11434/api/tags")
	print("Request Error Code: ", err)
	if err == OK:
		var result = await http.request_completed
		print("Response Code: ", result[1])
	else:
		print("Failed to start request")
	quit()
