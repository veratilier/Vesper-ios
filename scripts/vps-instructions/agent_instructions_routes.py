"""Registered only behind the existing history-service authentication."""
from vesper_agent_instructions import document, save, RevisionConflict


def dispatch(handler, path, services):
    if path != ['agent-instructions']:
        return False
    if handler.command not in ('GET', 'POST'):
        handler.send_json(405, {'error': 'Use GET or POST'})
        return True
    try:
        if handler.command == 'POST':
            try:
                body = handler.body()
                result = save(body.get('content'), body.get('revision'))
            except RevisionConflict:
                handler.send_json(409, {'error': 'Instructions changed elsewhere. Reload before saving.',
                                       'code': 'instructions_conflict'})
                return True
            except (ValueError, UnicodeError) as error:
                handler.send_json(400, {'error': str(error)})
                return True
        else:
            result = document()
        handler.send_json(200, result)
    except (OSError, UnicodeError, ValueError):
        handler.send_json(503, {'error': 'Shared agent instructions are unavailable'})
    return True
