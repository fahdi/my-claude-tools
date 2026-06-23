"""Parse a Claude Code transcript JSONL file.

Returns (tool_count, messages) where:
  tool_count — number of tool_use + tool_result blocks seen
  messages   — up to 25 text snippets as "role: text[:300]" strings,
               only lines with text longer than 20 chars
"""

import json
import sys


def parse_transcript(path):
    messages = []
    tool_use_count = 0

    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError:
        return 0, []

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue

        # Support both wrapped {type, message: {role, content}} and bare {role, content}
        inner = msg.get('message', msg)
        role = inner.get('role', '') or msg.get('type', '')
        content = inner.get('content', '')

        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get('type') in ('tool_use', 'tool_result'):
                    tool_use_count += 1
            text_parts = [
                p.get('text', '') for p in content
                if isinstance(p, dict) and p.get('type') == 'text'
                and p.get('text', '').strip()
            ]
            text = ' '.join(text_parts)
        elif isinstance(content, str):
            text = content
        else:
            text = ''

        if text and len(text.strip()) > 20:
            snippet = text.strip()[:300].replace('\n', ' ')
            messages.append(f'{role}: {snippet}')

    return tool_use_count, messages[-25:]


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('usage: parse_transcript.py <transcript.jsonl>', file=sys.stderr)
        sys.exit(1)
    count, msgs = parse_transcript(sys.argv[1])
    print(count)
    for m in msgs:
        print(m)
