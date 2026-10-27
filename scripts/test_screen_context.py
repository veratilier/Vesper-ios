"""Run actual Swift screen-context filtering against reload and mixed-batch fixtures."""
from pathlib import Path
import os
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
source=(root/'Vesper/Core/ChatTranscript.swift').read_text()
context=source[source.index('enum ChatScreenContext {'):source.index('enum ChatDeviceOrigin {')]
batch=source[source.index('    static func batchOriginals('):source.index('    static func part(')]
tests=r'''
func message(_ id: String, _ text: String, role: String = "user", image: String? = nil) -> JSONValue {
    var value: JSONValue = .object(["id": .string(id), "role": .string(role), "content": .string(text), "metadata": .object([:])])
    if let image { value["metadata"]["attachments"] = .array([.object(["id": .string(image), "type": .string("image/jpeg")])]) }
    return value
}
var live=message("sample", "pending screen sample")
live["metadata"]["internalScreenContext"] = .bool(true)
assert(ChatScreenContext.visibleRecords(live).isEmpty)
let decoded=try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(live))
assert(ChatScreenContext.visibleRecords(decoded).isEmpty)
let legacy=message("old",ChatScreenContext.macPrompt,image:"screen.jpg")
assert(ChatScreenContext.visibleRecords(legacy).isEmpty)
var recovered=legacy; recovered["content"] = .string(ChatScreenContext.macPrompt + "\n[Music context]")
assert(ChatScreenContext.visibleRecords(recovered).isEmpty)
let photo=message("real-photo","看看这个截图",image:"user.jpg")
assert(ChatScreenContext.visibleRecords(photo)==[photo])
let quoted=message("quoted","为什么会显示这个 prompt："+ChatScreenContext.macPrompt,image:"user.jpg")
assert(ChatScreenContext.visibleRecords(quoted)==[quoted])
var reply=message("reply",ChatScreenContext.macPrompt,role:"agent",image:"reply.jpg")
reply["metadata"]["internalScreenContext"] = .bool(true)
assert(ChatScreenContext.visibleRecords(reply)==[reply])
var queued=message("queued",ChatScreenContext.macPrompt)
queued["metadata"]["originDevice"] = .string("Mac")
assert(ChatScreenContext.visibleRecords(queued).isEmpty)
var first=legacy, second=photo
first["metadata"]["batchAttachmentIndices"] = .array([.number(0)])
second["metadata"]["batchAttachmentIndices"] = .array([.number(1)])
var parent=message("batch","original batch")
parent["metadata"]["batchMessages"] = .array([first,second])
parent["metadata"]["attachments"] = .array(legacy["metadata"]["attachments"].array + photo["metadata"]["attachments"].array)
let retained=ChatScreenContext.visibleRecords(parent)
assert(retained.count==1)
assert(retained[0]["content"]==photo["content"])
assert(retained[0]["metadata"]["attachments"]==photo["metadata"]["attachments"])
assert(retained[0]["metadata"]["sourceMessageId"].string=="batch")
assert(parent["metadata"]["batchMessages"].array.count==2, "Presentation must not mutate history")
var ordinary=parent; ordinary["metadata"]["batchMessages"] = .array([second])
assert(ChatScreenContext.visibleRecords(ordinary)==[ordinary])
print("PASS: live/reloaded/legacy screen samples hidden; replies, user photos and mixed-batch attachments preserved")
'''
with tempfile.TemporaryDirectory(prefix='vesper-screen-test-') as directory:
    path=Path(directory)
    (path/'main.swift').write_text('import Foundation\n'+context+'\nenum ChatBubbles {\n'+batch+'}\n'+tests)
    subprocess.run(['xcrun','swiftc',str(root/'Vesper/Core/JSONValue.swift'),str(path/'main.swift'),'-o',str(path/'check')],check=True)
    subprocess.run([str(path/'check')],check=True)
