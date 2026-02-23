# Confluence Upload Tool - Cursor AI Documentation

This document provides guidance for Cursor AI when working with the `confluence_upload.py` script.

## Overview

The `confluence_upload.py` script is a command-line tool for uploading markdown documentation to Atlassian Confluence. It handles authentication, markdown conversion, page creation/updates, and label management.

## File Location

```
/root/workspace/ppanda/scripts/confluence/confluence_upload.py
```

## Quick Reference

### Basic Usage

```bash
# Upload a markdown file to Confluence
python confluence_upload.py \
    --file <path/to/file.md> \
    --title "Page Title" \
    --space "SpaceKey" \
    --url "https://yourinstance.atlassian.net" \
    --email "user@example.com" \
    --token "YOUR_API_TOKEN"
```

### With Environment Variables

```bash
# Set environment variables first
export CONFLUENCE_URL="https://yourinstance.atlassian.net"
export CONFLUENCE_EMAIL="user@example.com"
export CONFLUENCE_API_KEY="YOUR_API_TOKEN"
export CONFLUENCE_SPACE="SpaceKey"

# Then upload
python confluence_upload.py --file docs/readme.md --title "My Page"
```

## Command-Line Arguments

| Argument | Short | Required | Description |
|----------|-------|----------|-------------|
| `--file` | `-f` | Yes | Path to markdown file |
| `--title` | `-t` | Yes | Confluence page title |
| `--url` | | No* | Confluence base URL |
| `--email` | | No* | Authentication email |
| `--token` | | No* | API token |
| `--space` | `-s` | No* | Confluence space key |
| `--labels` | `-l` | No | Comma-separated labels |
| `--parent-id` | `-p` | No | Parent page ID |
| `--log-level` | | No | DEBUG/INFO/WARNING/ERROR/CRITICAL |
| `--verbose` | `-v` | No | Enable INFO logging |
| `--debug` | `-d` | No | Enable DEBUG logging |
| `--quiet` | `-q` | No | Suppress output |
| `--json` | | No | Output as JSON |
| `--no-update` | | No | Don't update existing pages |
| `--convert-markdown` | | No | Convert to native format |

*\*Required if not set via environment variable*

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CONFLUENCE_URL` | Base URL (e.g., `https://company.atlassian.net`) |
| `CONFLUENCE_EMAIL` | Email for authentication |
| `CONFLUENCE_API_KEY` | API token from Atlassian |
| `CONFLUENCE_SPACE` | Default space key |

## Common Tasks

### Task: Upload New Documentation

```bash
python confluence_upload.py \
    --file /path/to/documentation.md \
    --title "CLIENT-ACME-INFRA-2026-01" \
    --space "Clients" \
    --labels "client-acme,infrastructure,2026" \
    --verbose
```

### Task: Update Existing Page

The script automatically updates existing pages with the same title:

```bash
python confluence_upload.py \
    --file /path/to/updated-doc.md \
    --title "Existing Page Title" \
    --verbose
```

### Task: Create Page Under Parent

```bash
python confluence_upload.py \
    --file /path/to/doc.md \
    --title "Child Page" \
    --parent-id "12345678" \
    --verbose
```

### Task: Debug Upload Issues

```bash
python confluence_upload.py \
    --file /path/to/doc.md \
    --title "Test Page" \
    --debug
```

### Task: Quiet Mode for Scripting

```bash
python confluence_upload.py \
    --file /path/to/doc.md \
    --title "Page" \
    --quiet \
    --json
```

## Code Architecture

### Classes

| Class | Purpose |
|-------|---------|
| `ConfluenceConfig` | Stores connection configuration |
| `MarkdownConverter` | Converts markdown to Confluence format |
| `ConfluenceClient` | REST API client for Confluence |
| `ConfluenceUploader` | Main orchestration class |
| `ConfluenceAPIError` | Custom exception for API errors |

### Logging Levels

| Level | Use Case |
|-------|----------|
| `DEBUG` | Detailed debugging info, API payloads |
| `INFO` | Progress updates, success messages |
| `WARNING` | Non-fatal issues (e.g., failed labels) |
| `ERROR` | Fatal errors that stop execution |
| `CRITICAL` | System-level failures |

**Default Level:** `ERROR`

### Key Methods

```python
# Create/update a page
uploader.upload(
    file_path=Path("doc.md"),
    title="Page Title",
    labels=["label1", "label2"],
    parent_id=None,
    update_existing=True,
    use_code_block=True
)

# Search for existing page
client.get_page_by_title("Page Title")

# Add labels to page
client.add_labels(page_id="12345", labels=["label1", "label2"])
```

## Error Handling

### Common Errors

1. **Missing Configuration**
   ```
   Error: Missing required configuration: base_url (CONFLUENCE_URL)
   ```
   Solution: Set the required environment variable or CLI argument.

2. **Authentication Failed**
   ```
   Error: Failed to create page: HTTP 401
   ```
   Solution: Verify email and API token are correct.

3. **Page Not Found (for updates)**
   ```
   Error: Page 'Title' already exists and update_existing=False
   ```
   Solution: Remove `--no-update` flag or change the title.

4. **Space Not Found**
   ```
   Error: Failed to create page: HTTP 404
   ```
   Solution: Verify the space key exists and you have access.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Configuration or file error |
| 2 | Confluence API error |
| 3 | Unexpected error |

## Integration Examples

### Bash Script Integration

```bash
#!/bin/bash
set -e

# Load credentials
source /path/to/.env

# Upload documentation
python /root/workspace/ppanda/scripts/confluence/confluence_upload.py \
    --file "$1" \
    --title "$2" \
    --labels "$3" \
    --verbose

echo "Upload complete!"
```

### Python Integration

```python
from confluence_upload import (
    ConfluenceConfig,
    ConfluenceUploader,
    setup_logging,
    LogLevel
)
from pathlib import Path

# Setup logging
setup_logging(LogLevel.INFO)

# Configure
config = ConfluenceConfig(
    base_url="https://company.atlassian.net",
    email="user@example.com",
    api_token="TOKEN",
    space_key="DOCS"
)

# Upload
uploader = ConfluenceUploader(config)
result = uploader.upload(
    file_path=Path("doc.md"),
    title="My Page",
    labels=["documentation"]
)

print(f"Page URL: {result['page_url']}")
```

## Best Practices

### Naming Convention for Pages

Follow the established pattern:

```
CLIENT-[CLIENT_CODE]-[CATEGORY]-[SUBCATEGORY]-[DATE]
```

Examples:
- `CLIENT-ACME-INFRA-CDN-2026-01`
- `CLIENT-BIGCORP-SEC-AUDIT-2026-02`

### Labels

Use lowercase labels without special characters:
- ✅ `client-acme`, `infrastructure`, `year-2026`
- ❌ `client:acme`, `Client-ACME`, `2026/01`

### Logging for Production

Use `ERROR` (default) or `WARNING` for production scripts:

```bash
python confluence_upload.py --file doc.md --title "Page" --log-level WARNING
```

### Logging for Development

Use `DEBUG` or `INFO` when troubleshooting:

```bash
python confluence_upload.py --file doc.md --title "Page" --debug
```

## Troubleshooting

### API Token Issues

1. Generate a new token at: https://id.atlassian.com/manage-profile/security/api-tokens
2. Use the token as a password with your email as username
3. Ensure the token has appropriate permissions for the space

### Network Issues

```bash
# Test connectivity
curl -u "email@example.com:TOKEN" \
    "https://company.atlassian.net/wiki/rest/api/space"
```

### Permission Issues

Verify you have:
- Read/write access to the target space
- Ability to add/edit pages
- Ability to add labels (if using labels)

## Dependencies

Required Python packages:
- `requests` (HTTP client)

Install with:
```bash
pip install requests
```

## Maintenance

### Adding New Features

1. Add new CLI arguments in `parse_arguments()`
2. Update `ConfluenceUploader.upload()` if needed
3. Add corresponding methods to `ConfluenceClient`
4. Update this CURSOR.md file

### Updating Markdown Conversion

Modify `MarkdownConverter._convert_markdown()` for new markdown features.
Note: The default mode uses code blocks for reliability.

### Adding New API Endpoints

Add methods to `ConfluenceClient` following the existing pattern:
1. Log the operation at INFO level
2. Make the API call with proper timeout
3. Call `_handle_response()` for error handling
4. Return the parsed JSON response

## Related Files

- `/root/workspace/.env` - Environment variables (credentials)
- `/root/workspace/CLIENT-*.md` - Client documentation files
- `/root/workspace/ppanda/ppanda-infrastructure/` - Infrastructure docs
- `/root/workspace/ppanda/scripts/confluence/` - This tool's directory

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-01-12 | Initial release with basic upload functionality |
