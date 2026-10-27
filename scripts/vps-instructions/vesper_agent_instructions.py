"""One bounded, freshly read instruction document for Vesper's model entry points."""
import fcntl
import tempfile
import hashlib
import os
from pathlib import Path

MAX_BYTES = 24000
BEGIN = '<vesper_shared_agent_instructions>'
END = '</vesper_shared_agent_instructions>'


def instruction_path():
    return Path(os.environ.get('VESPER_AGENT_INSTRUCTIONS', str(Path.home() / 'AGENTS.md')))


def validate(content):
    if not isinstance(content, str) or len(content.encode('utf-8')) > MAX_BYTES:
        raise ValueError('Instructions must be text, up to 24000 UTF-8 bytes')
    content = content.strip()
    if not content or BEGIN in content or END in content:
        raise ValueError('Instructions cannot be empty or contain reserved delimiters')
    return {'content': content, 'revision': hashlib.sha256(content.encode('utf-8')).hexdigest(),
            'source': 'AGENTS.md', 'version': 1}


def document():
    with instruction_path().open('rb') as stream:
        raw = stream.read(MAX_BYTES + 1)
    return validate(raw.decode('utf-8'))


class RevisionConflict(Exception):
    pass


def save(content, revision):
    updated = validate(content)
    if not isinstance(revision, str) or len(revision) != 64:
        raise ValueError('The current revision is required')
    path = instruction_path()
    lock_fd = os.open(str(path) + '.lock', os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(lock_fd, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = document()
        if current['revision'] != revision:
            raise RevisionConflict()
        if current['revision'] == updated['revision']:
            return current
        # Keep the immediately previous version locally for recovery.
        atomic_write(path.with_name(path.name + '.previous'), current['content'])
        atomic_write(path, updated['content'])
        return updated


def atomic_write(path, content):
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def compose(supplement='', shared=None):
    shared = document() if shared is None else shared
    # Refresh our own previous block without duplicating it on repeated resumes.
    if supplement.startswith(BEGIN + '\n') and END in supplement:
        supplement = supplement.split(END, 1)[1].lstrip('\n')
    return BEGIN + '\n' + shared['content'] + '\n' + END + '\n\n' + supplement


def prepare(method, params):
    # A resume with no explicit instructions must retain its stored scene rules.
    # The morning-dream entry point supplies its own scene instructions explicitly.
    if method not in ('thread/start', 'thread/resume') or (method == 'thread/resume' and 'developerInstructions' not in params):
        return params
    return dict(params, developerInstructions=compose(params.get('developerInstructions') or ''))
