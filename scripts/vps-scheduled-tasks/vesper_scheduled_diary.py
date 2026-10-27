"""Bounded diary tools for unattended scheduled tasks.

The scheduled Codex thread only receives VPS dynamic tools. These wrappers use
the owner's existing Vesper read/write permissions and return one date at a time.
"""
from __future__ import annotations

import re
from datetime import date as calendar_date


READ = 'get_vesper_diary_date'
WRITE = 'write_vesper_diary_date'


def available(allowed):
    names = set()
    if 'read_vesper_state' in allowed:
        names.add(READ)
        if 'write_vesper_state' in allowed:
            names.add(WRITE)
    return names


def definitions(allowed):
    names = available(allowed)
    result = []
    if READ in names:
        result.append({'type': 'function', 'name': READ,
            'description': 'Read only one dated Vesper journal entry. Returns entry:null when the date is empty. Use this for scheduled diary work instead of reading the entire journal.',
            'inputSchema': {'type': 'object', 'additionalProperties': False,
                'properties': {'date': {'type': 'string', 'description': 'YYYY-MM-DD'}},
                'required': ['date']}})
    if WRITE in names:
        result.append({'type': 'function', 'name': WRITE,
            'description': 'Save Ash’s diary text for one date only if no agent diary exists. Preserves Vera’s diary and other dates; refuses to overwrite different existing agent text. Reads the date back to verify the write.',
            'inputSchema': {'type': 'object', 'additionalProperties': False,
                'properties': {'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
                    'content': {'type': 'string', 'minLength': 1, 'maxLength': 12000}},
                'required': ['date', 'content']}})
    return result


def _date(arguments):
    value = arguments.get('date')
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
        raise ValueError('Diary date must be YYYY-MM-DD')
    try:
        calendar_date.fromisoformat(value)
    except ValueError:
        raise ValueError('Diary date is invalid') from None
    return value


def _backend(runner, name, arguments, context):
    response = runner.http('/api/codex/tools', {'name': name, 'arguments': arguments, **context})
    if not isinstance(response, dict) or 'result' not in response:
        raise RuntimeError('Vesper diary tool returned no result')
    result = response['result']
    if isinstance(result, dict) and result.get('isError'):
        raise RuntimeError('Vesper diary tool failed')
    return result


def _entry(runner, day, context):
    result = _backend(runner, 'read_vesper_state', {'section': 'journal'}, context)
    if not isinstance(result, dict) or result.get('section') != 'journal' or not isinstance(result.get('value'), dict):
        raise RuntimeError('Vesper journal could not be read safely')
    entry = result['value'].get(day)
    if entry is not None and not isinstance(entry, dict):
        raise RuntimeError('Vesper journal entry has an unexpected format')
    return entry


def _bounded_entry(entry):
    if entry is None:
        return None
    result = {}
    for author in ('user', 'agent'):
        value = entry.get(author)
        if value is not None and not isinstance(value, str):
            raise RuntimeError('Vesper journal author entry has an unexpected format')
        if isinstance(value, str):
            result[author] = value[:7000]
            if len(value) > 7000:
                result[author + 'Truncated'] = True
    return result


def execute(runner, name, arguments, context):
    day = _date(arguments)
    if name == READ:
        return {'date': day, 'entry': _bounded_entry(_entry(runner, day, context))}
    if name != WRITE:
        raise ValueError('Unknown scheduled diary tool')
    content = arguments.get('content')
    if not isinstance(content, str) or not 1 <= len(content.strip()) <= 12000:
        raise ValueError('Diary content must be 1–12000 characters')
    content = content.strip()
    before = _entry(runner, day, context)
    existing = before.get('agent') if before else None
    if existing is not None and not isinstance(existing, str):
        raise RuntimeError('Existing Ash diary has an unexpected format')
    if isinstance(existing, str) and existing.strip():
        if existing.strip() == content:
            return {'date': day, 'saved': True, 'verified': True, 'alreadyPresent': True}
        return {'date': day, 'saved': False, 'reason': 'Ash already has a diary entry for this date; nothing was overwritten'}
    result = _backend(runner, 'write_vesper_state',
        {'kind': 'journal', 'date': day, 'text': content}, context)
    if not isinstance(result, dict) or result.get('saved') is not True or result.get('date') != day:
        raise RuntimeError('Vesper did not confirm the diary write')
    after = _entry(runner, day, context)
    if not after or after.get('agent') != content:
        raise RuntimeError('Vesper diary write could not be verified')
    return {'date': day, 'saved': True, 'verified': True, 'alreadyPresent': False}
