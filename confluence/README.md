# Confluence Upload Tool

A command-line tool for uploading markdown documentation to Atlassian Confluence.

## Installation

```bash
pip install -r requirements.txt
```

## Quick Start

```bash
# Set environment variables
export CONFLUENCE_URL="https://yourinstance.atlassian.net"
export CONFLUENCE_EMAIL="user@example.com"
export CONFLUENCE_API_KEY="YOUR_API_TOKEN"
export CONFLUENCE_SPACE="SpaceKey"

# Upload a document
python confluence_upload.py --file document.md --title "Page Title"
```

## Usage

```bash
python confluence_upload.py [OPTIONS]

Required:
  -f, --file FILE      Path to markdown file
  -t, --title TITLE    Confluence page title

Optional:
  --url URL            Confluence base URL
  --email EMAIL        Authentication email
  --token TOKEN        API token
  -s, --space SPACE    Space key
  -l, --labels LABELS  Comma-separated labels
  -p, --parent-id ID   Parent page ID
  -v, --verbose        INFO logging
  -d, --debug          DEBUG logging
  -q, --quiet          Suppress output
  --json               JSON output
```

## Examples

```bash
# Verbose output
python confluence_upload.py -f doc.md -t "My Page" -v

# With labels
python confluence_upload.py -f doc.md -t "My Page" -l "tag1,tag2,tag3"

# JSON output for scripting
python confluence_upload.py -f doc.md -t "My Page" --json --quiet
```

## Files

| File | Description |
|------|-------------|
| `confluence_upload.py` | Main script |
| `CURSOR.md` | Cursor AI documentation |
| `requirements.txt` | Python dependencies |
| `README.md` | This file |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CONFLUENCE_URL` | Base URL (e.g., `https://company.atlassian.net`) |
| `CONFLUENCE_EMAIL` | Email for authentication |
| `CONFLUENCE_API_KEY` | API token |
| `CONFLUENCE_SPACE` | Default space key |

## License

Internal use only.
