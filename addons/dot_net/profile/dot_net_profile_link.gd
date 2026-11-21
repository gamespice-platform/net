class_name GSNetProfileLink
extends RefCounted

## Carries GameSpice Core's [GSProfileRuntime] over a [GSNetManager]: requests up, rows down. Opt-in:
## [code]GSNetProfileLink.attach(manager, runtime)[/code] before the manager starts (message types
## seal on first use); then [method peer_joined] per peer, [method submit] a request, [member actor_of].

const CHANNEL := "profile"
const TYPE_REQUEST := &"profile.request"
const TYPE_ROW := &"profile.row"
const TYPE_REPLY := &"profile.reply"
## The server's peer id in Godot's multiplayer numbering.
const SERVER_PEER := 1
## Defaults for [member max_request_bytes] and [member max_row_bytes].
const MAX_REQUEST := 2048
const MAX_ROW := 8192

## Longest request body; it must fit a client payload (4096 by default). 0 = unlimited (up to
## the writer's runaway guard). Both ends must agree: the reader refuses a longer one.
static var max_request_bytes: int = MAX_REQUEST
## Longest row body, the server's own. 0 = unlimited. A longer row is not sent, with an error,
## rather than truncated into JSON the client cannot read.
static var max_row_bytes: int = MAX_ROW


## The wire bound for a [param setting] of 0 = unlimited.
static func wire_bound(setting: int) -> int:
	return setting if setting > 0 else GSNetWriter.MAX_BYTES

## A server's answer to the peer that made a request.
signal reply(ok: bool, text: String)

## [code](peer_id: int) -> Variant[/code]: who a peer is to the permission check (a uid for
## GameSpice Server's admins). Unset, the actor is the peer id.
var actor_of: Callable = Callable()
## The actor for a request made on the server itself (its console).
var local_actor: Variant = "server"

var manager: GSNetManager = null
var runtime: GSProfileRuntime = null


## Registers the three message types on [param manager] and routes [param runtime] through
## them. Returns null (and logs) when the registry refuses.
static func attach(manager_: GSNetManager, runtime_: GSProfileRuntime) -> GSNetProfileLink:
	var link := GSNetProfileLink.new()
	link.manager = manager_
	link.runtime = runtime_
	var msgs := manager_.messages
	var first := msgs.register(TYPE_REQUEST, RequestMessage, GSNetMessage.Delivery.RELIABLE, GSNetMessage.Direction.TO_SERVER, false)
	var second := msgs.register(TYPE_ROW, RowMessage, GSNetMessage.Delivery.RELIABLE, GSNetMessage.Direction.TO_CLIENT, false)
	var third := msgs.register(TYPE_REPLY, ReplyMessage, GSNetMessage.Delivery.RELIABLE, GSNetMessage.Direction.TO_CLIENT, false)
	for res in [first, second, third]:
		if not res.ok:
			GSLog.warn(CHANNEL, "profile link not attached", {"why": res.error.message})
			return null
	msgs.on(TYPE_REQUEST, link._on_request)
	msgs.on(TYPE_ROW, link._on_row)
	msgs.on(TYPE_REPLY, link._on_reply)
	if manager_.is_server:
		runtime_.broadcast = func(row: Dictionary) -> void: link._send_row(0, row)
		runtime_.send_to = func(peer: Variant, row: Dictionary) -> void: link._send_row(int(peer), row)
	return link


## Breaks the link/runtime reference cycle; call when the connection is torn down.
func release() -> void:
	if runtime != null:
		runtime.broadcast = Callable()
		runtime.send_to = Callable()
	runtime = null
	manager = null


## Server: sends [param peer_id] every edited profile. Call after [method GSNetManager.add_peer].
func peer_joined(peer_id: int) -> void:
	runtime.send_snapshot(peer_id)


## Makes an edit. On a client it goes to the server and the answer arrives on [signal reply]
## (the value here is true once sent); on the server it runs at once as [member local_actor].
func submit(req: Dictionary) -> GSResult:
	if manager.is_server:
		return runtime.handle_request(local_actor, req)
	var msg := RequestMessage.new()
	var body := encode_body(req)
	var size := body.to_utf8_buffer().size()
	if size > wire_bound(max_request_bytes):
		return GSResult.fail(GSError.CODE_INVALID, "profile request too large (max_request_bytes, 0 = unlimited)",
			"%d > %d" % [size, wire_bound(max_request_bytes)])
	msg.body = body
	var sent := manager.send(msg, SERVER_PEER)
	return sent if not sent.ok else GSResult.success(true)


## Server side of one request from [param peer_id]; returns what [code]handle_request[/code]
## did, or an error for a body that is not a request. Replies to the peer.
func handle_from_peer(peer_id: int, body: String) -> GSResult:
	var decoded := decode_body(body)
	var res: GSResult
	if not decoded.ok:
		res = decoded
	else:
		var actor: Variant = actor_of.call(peer_id) if actor_of.is_valid() else peer_id
		res = runtime.handle_request(actor, decoded.value)
	var msg := ReplyMessage.new()
	msg.ok = res.ok
	msg.text = "ok" if res.ok else res.error.message
	manager.send(msg, peer_id)
	return res


## Request or row to a string that keeps int against float and refuses objects.
static func encode_body(data: Dictionary) -> String:
	return JSON.stringify(JSON.from_native(data, false))


## The inverse; value is the Dictionary, or a CODE_INVALID error.
static func decode_body(body: String) -> GSResult:
	var json := JSON.new()
	if json.parse(body) != OK:
		return GSResult.fail(GSError.CODE_INVALID, "profile message is not JSON")
	var parsed: Variant = json.data
	if not (parsed is Dictionary) or not _plain(parsed, 0):
		return GSResult.fail(GSError.CODE_INVALID, "profile message is not an encoded dictionary")
	var native: Variant = JSON.to_native(parsed, false)
	if not (native is Dictionary):
		return GSResult.fail(GSError.CODE_INVALID, "profile message is not a dictionary")
	return GSResult.success(native)


## Only the shapes [code]JSON.from_native[/code] writes for plain data; anything else would
## reach the decoder, which logs an engine error per malformed node (a flood from a hostile peer).
static func _plain(node: Variant, depth: int) -> bool:
	if depth > 8:
		return false
	if node == null or node is bool:
		return true
	if node is String:
		return node.begins_with("s:") or node.begins_with("i:") or node.begins_with("f:")
	if node is Array:
		for item in node:
			if not _plain(item, depth + 1):
				return false
		return true
	if node is Dictionary:
		var args: Variant = node.get("args")
		return node.size() == 2 and node.get("type") == "Dictionary" and args is Array \
			and args.size() % 2 == 0 and _plain(args, depth + 1)
	return false


func _send_row(peer_id: int, row: Dictionary) -> void:
	var msg := RowMessage.new()
	msg.body = encode_body(row)
	var size := msg.body.to_utf8_buffer().size()
	if size > wire_bound(max_row_bytes):
		GSLog.error(CHANNEL, "profile row not sent: too large (raise max_row_bytes, 0 = unlimited)",
			{"bytes": size, "max_row_bytes": max_row_bytes, "peer": peer_id})
		return
	manager.send(msg, peer_id)


func _on_request(msg: GSNetMessage) -> void:
	if manager.is_server:
		handle_from_peer(msg.sender_peer_id, (msg as RequestMessage).body)


func _on_row(msg: GSNetMessage) -> void:
	if manager.is_server:
		return
	var decoded := decode_body((msg as RowMessage).body)
	if not decoded.ok:
		GSLog.warn(CHANNEL, "bad profile row", {"why": decoded.error.message})
	else:
		var applied := runtime.apply_row(decoded.value)
		if not applied.ok:
			GSLog.warn(CHANNEL, "bad profile row", {"why": applied.error.message})


func _on_reply(msg: GSNetMessage) -> void:
	var r := msg as ReplyMessage
	reply.emit(r.ok, r.text)


class RequestMessage extends GSNetMessage:
	var body := ""

	func _type_name() -> StringName: return GSNetProfileLink.TYPE_REQUEST
	func _write(w: GSNetWriter) -> void: w.write_string(body, GSNetProfileLink.wire_bound(GSNetProfileLink.max_request_bytes))
	func _read(r: GSNetReader) -> void: body = r.read_string(GSNetProfileLink.wire_bound(GSNetProfileLink.max_request_bytes))


class RowMessage extends GSNetMessage:
	var body := ""

	func _type_name() -> StringName: return GSNetProfileLink.TYPE_ROW
	func _write(w: GSNetWriter) -> void: w.write_string(body, GSNetProfileLink.wire_bound(GSNetProfileLink.max_row_bytes))
	func _read(r: GSNetReader) -> void: body = r.read_string(GSNetProfileLink.wire_bound(GSNetProfileLink.max_row_bytes))


class ReplyMessage extends GSNetMessage:
	var ok := false
	var text := ""

	func _type_name() -> StringName: return GSNetProfileLink.TYPE_REPLY
	func _write(w: GSNetWriter) -> void:
		w.write_bool(ok)
		w.write_string(text, 256)
	func _read(r: GSNetReader) -> void:
		ok = r.read_bool()
		text = r.read_string(256)
