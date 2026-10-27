"""Test the production Swift reaction identity without accessing live history."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Vesper/Core/ChatTranscript.swift').read_text()
bubbles = source[source.index('    static func texts(_ text: String)'):source.index('    static func quote(_ part: JSONValue')]
source = source[source.index('enum ChatReactions {'):source.index('enum ChatTranscript {')]
source += '\nenum ChatBubbles {\n' + bubbles + '\n}\n'
source += 'enum ChatPresentation { static func isUser(_ m: JSONValue) -> Bool { m["role"].string == "user" }; static func isActivity(_ m: JSONValue) -> Bool { m["role"].string == "system" } }\n'
source += 'enum DesireEmotion { static func visible(_ s: String) -> String { s } }\n' 
tests = r'''
let first: JSONValue = .object(["id":.string("m#text-0"), "content":.string("first"), "metadata":.object(["sourceMessageId":.string("m")])])
let second: JSONValue = .object(["id":.string("m#text-1"), "content":.string("second"), "metadata":.object(["sourceMessageId":.string("m")])])
let saved: JSONValue = .object(["id":.string("m"),"metadata":.object(["reactions":.object([ChatReactions.key(first):.object(["emoji":.string("❤️")])])])])
assert(ChatReactions.emoji(first,in:[saved]) == "❤️")
assert(ChatReactions.emoji(second,in:[saved]).isEmpty)
let reloaded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(saved))
assert(ChatReactions.emoji(first,in:[reloaded]) == "❤️")
var replacement=first; replacement["content"] = .string("different bubble")
assert(ChatReactions.emoji(replacement,in:[saved]).isEmpty)
var changedURL=first; changedURL["metadata"]["url"] = .string("https://example.invalid/refreshed")
assert(ChatReactions.key(first)==ChatReactions.key(changedURL))
for emoji in ["❤️", "👍🏽", "👩‍💻", "🇨🇳"] { assert(ChatReactions.valid(emoji)) }
for invalid in ["", "hello", "12", "👍❤️"] { assert(!ChatReactions.valid(invalid)) }
let child1: JSONValue = .object(["role": .string("user"), "content": .string("one"), "metadata": .object(["batchKey": .string("a")])])
let child2: JSONValue = .object(["role": .string("user"), "content": .string("two"), "metadata": .object(["batchKey": .string("b")])])
var batch: JSONValue = .object(["id": .string("batch"), "role": .string("user"), "status": .string("delivered"), "metadata": .object(["batchMessages": .array([child1, child2])])])
let parts = ChatReactionContext.parts(batch)
assert(parts.count == 2 && parts[0].id == "batch#a#text-0" && parts[1].id == "batch#b#text-0")
assert(ChatReactions.sourceID(parts[1]) == "batch")
batch["metadata"]["reactions"][ChatReactions.key(parts[1])] = .object(["emoji": .string("🥹"), "by": .string("agent")])
let record = ChatReactionContext.record(batch)
assert(record["bubbles"].array[0]["reaction"] == .null)
assert(record["bubbles"].array[1]["reaction"]["by"].string == "agent")
assert(ChatReactionContext.reactionSummary(batch)["bubbles"].array.count == 1)
assert(ChatReactionContext.reactionSummary(batch)["bubbles"].array[0]["text"].string == "two")
batch["metadata"]["reactions"] = .object([:])
assert(ChatReactionContext.reactionSummary(batch)["bubbles"].array.isEmpty)
var assistant: JSONValue = .object(["id": .string("a"), "role": .string("agent"), "content": .string("First.\n\nSecond."), "metadata": .object([:])])
let ap = ChatReactionContext.parts(assistant)
assistant["metadata"]["reactions"][ChatReactions.key(ap[1])] = .object(["emoji": .string("❤️"), "by": .string("user")])
let summary = ChatReactionContext.reactionSummary(assistant)
assert(summary["bubbles"].array[0]["text"].string == "Second.")
assert(summary["bubbles"].array[0]["reaction"]["by"].string == "user")
print("PASS: per-bubble reaction, reload, replaced content, stable identity and composite emoji")
'''
with tempfile.TemporaryDirectory(prefix='vesper-reactions-test-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text('import Foundation\nimport CryptoKit\n' + source + tests)
    subprocess.run(['xcrun', 'swiftc', str(root / 'Vesper/Core/JSONValue.swift'), str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
