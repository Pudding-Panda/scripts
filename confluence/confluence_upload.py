#!/usr/bin/env python3
"""
Confluence Documentation Upload Tool

A command-line tool for uploading markdown documentation to Atlassian Confluence.
Supports automatic conversion from markdown to Confluence storage format,
label management, and flexible authentication options.

Usage:
    python confluence_upload.py --file <markdown_file> --title <page_title> [options]

Example:
    python confluence_upload.py \\
        --file docs/infrastructure.md \\
        --title "CLIENT-ACME-INFRA-CDN-2026-01" \\
        --space "Clients" \\
        --labels "cdn,gcp,infrastructure"
"""

import argparse
import html
import json
import logging
import os
import re
import sys
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional

import requests
from requests.auth import HTTPBasicAuth


# =============================================================================
# CONFIGURATION
# =============================================================================

class LogLevel(Enum):
    """Supported logging levels."""
    DEBUG = logging.DEBUG
    INFO = logging.INFO
    WARNING = logging.WARNING
    ERROR = logging.ERROR
    CRITICAL = logging.CRITICAL


@dataclass
class ConfluenceConfig:
    """Configuration for Confluence connection."""
    base_url: str
    email: str
    api_token: str
    space_key: str

    @classmethod
    def from_env(cls) -> "ConfluenceConfig":
        """Create configuration from environment variables."""
        return cls(
            base_url=os.getenv("CONFLUENCE_URL", ""),
            email=os.getenv("CONFLUENCE_EMAIL", ""),
            api_token=os.getenv("CONFLUENCE_API_KEY", ""),
            space_key=os.getenv("CONFLUENCE_SPACE", ""),
        )

    def validate(self) -> list[str]:
        """Validate configuration and return list of missing fields."""
        missing = []
        if not self.base_url:
            missing.append("base_url (CONFLUENCE_URL)")
        if not self.email:
            missing.append("email (CONFLUENCE_EMAIL)")
        if not self.api_token:
            missing.append("api_token (CONFLUENCE_API_KEY)")
        if not self.space_key:
            missing.append("space_key (CONFLUENCE_SPACE)")
        return missing


# =============================================================================
# LOGGING SETUP
# =============================================================================

def setup_logging(level: LogLevel = LogLevel.ERROR) -> logging.Logger:
    """
    Configure and return a logger with the specified level.

    Args:
        level: The logging level to use.

    Returns:
        Configured logger instance.
    """
    logger = logging.getLogger("confluence_upload")
    logger.setLevel(level.value)

    # Remove existing handlers to avoid duplicates
    logger.handlers.clear()

    # Console handler with formatting
    console_handler = logging.StreamHandler(sys.stderr)
    console_handler.setLevel(level.value)

    # Format varies by level
    if level == LogLevel.DEBUG:
        formatter = logging.Formatter(
            "%(asctime)s | %(levelname)-8s | %(funcName)s:%(lineno)d | %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S"
        )
    else:
        formatter = logging.Formatter(
            "%(levelname)-8s | %(message)s"
        )

    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    return logger


# Global logger instance (configured at runtime)
logger: logging.Logger = logging.getLogger("confluence_upload")


# =============================================================================
# MARKDOWN CONVERSION
# =============================================================================

class MarkdownConverter:
    """Converts markdown content to Confluence storage format."""

    def __init__(self):
        """Initialize the markdown converter."""
        self.logger = logging.getLogger("confluence_upload.converter")

    def convert(self, markdown_content: str, use_code_block: bool = True) -> str:
        """
        Convert markdown to Confluence storage format.

        Args:
            markdown_content: Raw markdown text.
            use_code_block: If True, wrap content in a code macro for preservation.
                           If False, attempt full conversion.

        Returns:
            Confluence storage format HTML.
        """
        self.logger.debug("Starting markdown conversion")

        if use_code_block:
            return self._wrap_in_code_block(markdown_content)

        return self._convert_markdown(markdown_content)

    def _wrap_in_code_block(self, content: str) -> str:
        """
        Wrap markdown content in a Confluence code macro.

        This preserves formatting exactly as-is.
        """
        self.logger.debug("Wrapping content in code block macro")

        return f"""<ac:structured-macro ac:name="code">
<ac:parameter ac:name="language">markdown</ac:parameter>
<ac:parameter ac:name="theme">Midnight</ac:parameter>
<ac:parameter ac:name="linenumbers">false</ac:parameter>
<ac:parameter ac:name="collapse">false</ac:parameter>
<ac:plain-text-body><![CDATA[
{content}
]]></ac:plain-text-body>
</ac:structured-macro>
<p><em>This documentation was automatically uploaded. View raw markdown above.</em></p>"""

    def _convert_markdown(self, content: str) -> str:
        """
        Attempt to convert markdown to Confluence storage format.

        Note: This is a simplified conversion. For complex documents,
        consider using the code block wrapper instead.
        """
        self.logger.debug("Converting markdown to Confluence format")

        lines = content.split("\n")
        result = []
        in_code_block = False
        in_list = False
        code_block_content = []
        code_language = ""

        for line in lines:
            # Handle code blocks
            if line.startswith("```"):
                if not in_code_block:
                    in_code_block = True
                    code_language = line[3:].strip() or "text"
                    code_block_content = []
                else:
                    in_code_block = False
                    code_content = "\n".join(code_block_content)
                    result.append(self._create_code_macro(code_content, code_language))
                continue

            if in_code_block:
                code_block_content.append(line)
                continue

            # Handle headers
            if line.startswith("#"):
                if in_list:
                    result.append("</ul>")
                    in_list = False
                result.append(self._convert_header(line))
                continue

            # Handle horizontal rules
            if line.strip() in ["---", "***", "___"]:
                result.append("<hr />")
                continue

            # Handle bullet lists
            if line.strip().startswith("- ") or line.strip().startswith("* "):
                if not in_list:
                    result.append("<ul>")
                    in_list = True
                list_content = line.strip()[2:]
                result.append(f"<li>{self._convert_inline(list_content)}</li>")
                continue

            # Handle numbered lists
            if re.match(r"^\d+\.\s", line.strip()):
                if not in_list:
                    result.append("<ol>")
                    in_list = True
                list_content = re.sub(r"^\d+\.\s", "", line.strip())
                result.append(f"<li>{self._convert_inline(list_content)}</li>")
                continue

            # End list if we're in one and hit a non-list line
            if in_list and line.strip():
                if line.strip().startswith("- ") or line.strip().startswith("* "):
                    pass  # Continue list
                else:
                    result.append("</ul>")
                    in_list = False

            # Handle tables (basic support)
            if "|" in line and line.strip().startswith("|"):
                result.append(self._convert_table_row(line))
                continue

            # Handle paragraphs
            if line.strip():
                result.append(f"<p>{self._convert_inline(line)}</p>")
            else:
                result.append("")

        # Close any open list
        if in_list:
            result.append("</ul>")

        return "\n".join(result)

    def _convert_header(self, line: str) -> str:
        """Convert a markdown header to HTML."""
        match = re.match(r"^(#{1,6})\s+(.+)$", line)
        if match:
            level = len(match.group(1))
            content = self._convert_inline(match.group(2))
            return f"<h{level}>{content}</h{level}>"
        return line

    def _convert_inline(self, text: str) -> str:
        """Convert inline markdown formatting."""
        # Escape HTML first
        text = html.escape(text)

        # Bold: **text** or __text__
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"__(.+?)__", r"<strong>\1</strong>", text)

        # Italic: *text* or _text_
        text = re.sub(r"\*(.+?)\*", r"<em>\1</em>", text)
        text = re.sub(r"_(.+?)_", r"<em>\1</em>", text)

        # Inline code: `code`
        text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)

        # Links: [text](url)
        text = re.sub(
            r"\[(.+?)\]\((.+?)\)",
            r'<a href="\2">\1</a>',
            text
        )

        # Checkboxes
        text = text.replace("✅", "✓")
        text = text.replace("❌", "✗")

        return text

    def _convert_table_row(self, line: str) -> str:
        """Convert a markdown table row to HTML."""
        cells = [c.strip() for c in line.split("|")[1:-1]]

        # Check if this is a separator row
        if all(re.match(r"^[-:]+$", cell) for cell in cells):
            return ""  # Skip separator rows

        row_html = "<tr>"
        for cell in cells:
            row_html += f"<td>{self._convert_inline(cell)}</td>"
        row_html += "</tr>"
        return row_html

    def _create_code_macro(self, content: str, language: str = "text") -> str:
        """Create a Confluence code macro."""
        return f"""<ac:structured-macro ac:name="code">
<ac:parameter ac:name="language">{language}</ac:parameter>
<ac:plain-text-body><![CDATA[{content}]]></ac:plain-text-body>
</ac:structured-macro>"""


# =============================================================================
# CONFLUENCE API CLIENT
# =============================================================================

class ConfluenceClient:
    """Client for interacting with the Confluence REST API."""

    def __init__(self, config: ConfluenceConfig):
        """
        Initialize the Confluence client.

        Args:
            config: Confluence connection configuration.
        """
        self.config = config
        self.base_api_url = f"{config.base_url}/wiki/rest/api"
        self.auth = HTTPBasicAuth(config.email, config.api_token)
        self.headers = {"Content-Type": "application/json"}
        self.logger = logging.getLogger("confluence_upload.client")

    def create_page(
        self,
        title: str,
        content: str,
        parent_id: Optional[str] = None
    ) -> dict:
        """
        Create a new Confluence page.

        Args:
            title: Page title.
            content: Page content in Confluence storage format.
            parent_id: Optional parent page ID for hierarchy.

        Returns:
            API response containing page details.

        Raises:
            ConfluenceAPIError: If the API request fails.
        """
        self.logger.info(f"Creating page: {title}")
        self.logger.debug(f"Space: {self.config.space_key}")

        payload = {
            "type": "page",
            "title": title,
            "space": {"key": self.config.space_key},
            "body": {
                "storage": {
                    "value": content,
                    "representation": "storage"
                }
            }
        }

        if parent_id:
            self.logger.debug(f"Parent page ID: {parent_id}")
            payload["ancestors"] = [{"id": parent_id}]

        response = requests.post(
            f"{self.base_api_url}/content",
            auth=self.auth,
            headers=self.headers,
            data=json.dumps(payload),
            timeout=30
        )

        self._handle_response(response, "create page")
        return response.json()

    def update_page(
        self,
        page_id: str,
        title: str,
        content: str,
        version: int
    ) -> dict:
        """
        Update an existing Confluence page.

        Args:
            page_id: ID of the page to update.
            title: New page title.
            content: New page content in Confluence storage format.
            version: Current version number (will be incremented).

        Returns:
            API response containing updated page details.

        Raises:
            ConfluenceAPIError: If the API request fails.
        """
        self.logger.info(f"Updating page: {page_id}")

        payload = {
            "type": "page",
            "title": title,
            "body": {
                "storage": {
                    "value": content,
                    "representation": "storage"
                }
            },
            "version": {"number": version + 1}
        }

        response = requests.put(
            f"{self.base_api_url}/content/{page_id}",
            auth=self.auth,
            headers=self.headers,
            data=json.dumps(payload),
            timeout=30
        )

        self._handle_response(response, "update page")
        return response.json()

    def get_page_by_title(self, title: str) -> Optional[dict]:
        """
        Find a page by its title.

        Args:
            title: Page title to search for.

        Returns:
            Page data if found, None otherwise.
        """
        self.logger.debug(f"Searching for page: {title}")

        params = {
            "title": title,
            "spaceKey": self.config.space_key,
            "expand": "version"
        }

        response = requests.get(
            f"{self.base_api_url}/content",
            auth=self.auth,
            headers=self.headers,
            params=params,
            timeout=30
        )

        self._handle_response(response, "search page")
        results = response.json().get("results", [])

        if results:
            self.logger.debug(f"Found page with ID: {results[0]['id']}")
            return results[0]

        self.logger.debug("Page not found")
        return None

    def add_labels(self, page_id: str, labels: list[str]) -> list[dict]:
        """
        Add labels to a Confluence page.

        Args:
            page_id: ID of the page.
            labels: List of label names.

        Returns:
            List of results for each label addition.
        """
        self.logger.info(f"Adding {len(labels)} labels to page {page_id}")
        results = []

        for label in labels:
            # Clean label name (Confluence doesn't allow special characters)
            clean_label = self._clean_label(label)
            if not clean_label:
                self.logger.warning(f"Skipping invalid label: {label}")
                continue

            self.logger.debug(f"Adding label: {clean_label}")

            payload = {"prefix": "global", "name": clean_label}

            response = requests.post(
                f"{self.base_api_url}/content/{page_id}/label",
                auth=self.auth,
                headers=self.headers,
                data=json.dumps(payload),
                timeout=30
            )

            if response.status_code in [200, 201]:
                self.logger.debug(f"Successfully added label: {clean_label}")
                results.append({"label": clean_label, "success": True})
            else:
                self.logger.warning(
                    f"Failed to add label '{clean_label}': {response.status_code}"
                )
                results.append({
                    "label": clean_label,
                    "success": False,
                    "error": response.text
                })

        return results

    def _clean_label(self, label: str) -> str:
        """
        Clean a label name for Confluence compatibility.

        Confluence labels cannot contain colons or special characters.
        """
        # Replace colons and special chars with hyphens
        clean = re.sub(r"[^a-zA-Z0-9_-]", "-", label)
        # Remove consecutive hyphens
        clean = re.sub(r"-+", "-", clean)
        # Remove leading/trailing hyphens
        clean = clean.strip("-")
        return clean.lower()

    def _handle_response(self, response: requests.Response, operation: str) -> None:
        """
        Handle API response and raise exception on error.

        Args:
            response: The requests Response object.
            operation: Description of the operation for error messages.

        Raises:
            ConfluenceAPIError: If the response indicates an error.
        """
        if response.status_code not in [200, 201]:
            error_msg = f"Failed to {operation}: HTTP {response.status_code}"
            self.logger.error(error_msg)
            self.logger.debug(f"Response body: {response.text}")
            raise ConfluenceAPIError(error_msg, response.status_code, response.text)


class ConfluenceAPIError(Exception):
    """Exception raised for Confluence API errors."""

    def __init__(self, message: str, status_code: int, response_body: str):
        """
        Initialize the exception.

        Args:
            message: Error message.
            status_code: HTTP status code.
            response_body: Raw response body.
        """
        super().__init__(message)
        self.status_code = status_code
        self.response_body = response_body


# =============================================================================
# MAIN APPLICATION
# =============================================================================

class ConfluenceUploader:
    """Main application for uploading documentation to Confluence."""

    def __init__(self, config: ConfluenceConfig):
        """
        Initialize the uploader.

        Args:
            config: Confluence connection configuration.
        """
        self.config = config
        self.client = ConfluenceClient(config)
        self.converter = MarkdownConverter()
        self.logger = logging.getLogger("confluence_upload.uploader")

    def upload(
        self,
        file_path: Path,
        title: str,
        labels: Optional[list[str]] = None,
        parent_id: Optional[str] = None,
        update_existing: bool = True,
        use_code_block: bool = True
    ) -> dict:
        """
        Upload a markdown file to Confluence.

        Args:
            file_path: Path to the markdown file.
            title: Page title in Confluence.
            labels: Optional list of labels to add.
            parent_id: Optional parent page ID.
            update_existing: If True, update page if it exists.
            use_code_block: If True, wrap content in code block.

        Returns:
            Dictionary with upload results.
        """
        self.logger.info(f"Starting upload: {file_path}")

        # Read markdown file
        self.logger.debug(f"Reading file: {file_path}")
        if not file_path.exists():
            raise FileNotFoundError(f"File not found: {file_path}")

        with open(file_path, "r", encoding="utf-8") as f:
            markdown_content = f.read()

        self.logger.debug(f"Read {len(markdown_content)} characters")

        # Convert to Confluence format
        confluence_content = self.converter.convert(
            markdown_content,
            use_code_block=use_code_block
        )

        # Check if page exists
        existing_page = self.client.get_page_by_title(title)

        if existing_page and update_existing:
            # Update existing page
            self.logger.info(f"Updating existing page: {existing_page['id']}")
            page_data = self.client.update_page(
                page_id=existing_page["id"],
                title=title,
                content=confluence_content,
                version=existing_page["version"]["number"]
            )
            action = "updated"
        elif existing_page and not update_existing:
            raise ValueError(
                f"Page '{title}' already exists and update_existing=False"
            )
        else:
            # Create new page
            page_data = self.client.create_page(
                title=title,
                content=confluence_content,
                parent_id=parent_id
            )
            action = "created"

        page_id = page_data["id"]
        page_url = f"{self.config.base_url}/wiki{page_data['_links']['webui']}"

        self.logger.info(f"Page {action} successfully: {page_url}")

        # Add labels
        label_results = []
        if labels:
            label_results = self.client.add_labels(page_id, labels)

        return {
            "action": action,
            "page_id": page_id,
            "page_url": page_url,
            "title": title,
            "labels": label_results
        }


# =============================================================================
# CLI INTERFACE
# =============================================================================

def parse_arguments() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Upload markdown documentation to Confluence",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Environment Variables:
  CONFLUENCE_URL       Base URL of your Confluence instance
  CONFLUENCE_EMAIL     Email address for authentication
  CONFLUENCE_API_KEY   API token for authentication
  CONFLUENCE_SPACE     Default space key

Examples:
  # Upload with environment variables configured
  %(prog)s --file docs/readme.md --title "My Documentation"

  # Upload with all options
  %(prog)s \\
      --url https://mycompany.atlassian.net \\
      --email user@example.com \\
      --token YOUR_API_TOKEN \\
      --space DOCS \\
      --file docs/readme.md \\
      --title "My Documentation" \\
      --labels "docs,project,v1" \\
      --log-level INFO
        """
    )

    # Required arguments
    parser.add_argument(
        "-f", "--file",
        type=Path,
        required=True,
        help="Path to the markdown file to upload"
    )
    parser.add_argument(
        "-t", "--title",
        type=str,
        required=True,
        help="Title for the Confluence page"
    )

    # Connection arguments (override environment variables)
    parser.add_argument(
        "--url",
        type=str,
        default=os.getenv("CONFLUENCE_URL"),
        help="Confluence base URL (env: CONFLUENCE_URL)"
    )
    parser.add_argument(
        "--email",
        type=str,
        default=os.getenv("CONFLUENCE_EMAIL"),
        help="Email for authentication (env: CONFLUENCE_EMAIL)"
    )
    parser.add_argument(
        "--token",
        type=str,
        default=os.getenv("CONFLUENCE_API_KEY"),
        help="API token for authentication (env: CONFLUENCE_API_KEY)"
    )
    parser.add_argument(
        "-s", "--space",
        type=str,
        default=os.getenv("CONFLUENCE_SPACE"),
        help="Confluence space key (env: CONFLUENCE_SPACE)"
    )

    # Optional arguments
    parser.add_argument(
        "-l", "--labels",
        type=str,
        default="",
        help="Comma-separated list of labels to add"
    )
    parser.add_argument(
        "-p", "--parent-id",
        type=str,
        default=None,
        help="Parent page ID for hierarchy"
    )
    parser.add_argument(
        "--no-update",
        action="store_true",
        help="Fail if page already exists (don't update)"
    )
    parser.add_argument(
        "--convert-markdown",
        action="store_true",
        help="Convert markdown to native format (experimental)"
    )

    # Logging arguments
    parser.add_argument(
        "--log-level",
        type=str,
        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
        default="ERROR",
        help="Logging level (default: ERROR)"
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose output (same as --log-level INFO)"
    )
    parser.add_argument(
        "-d", "--debug",
        action="store_true",
        help="Enable debug output (same as --log-level DEBUG)"
    )

    # Output arguments
    parser.add_argument(
        "-q", "--quiet",
        action="store_true",
        help="Suppress all output except errors"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output results as JSON"
    )

    return parser.parse_args()


def main() -> int:
    """
    Main entry point for the CLI.

    Returns:
        Exit code (0 for success, non-zero for failure).
    """
    args = parse_arguments()

    # Determine log level
    if args.debug:
        log_level = LogLevel.DEBUG
    elif args.verbose:
        log_level = LogLevel.INFO
    elif args.quiet:
        log_level = LogLevel.CRITICAL
    else:
        log_level = LogLevel[args.log_level]

    # Setup logging
    global logger
    logger = setup_logging(log_level)

    logger.debug("Starting Confluence upload tool")
    logger.debug(f"Arguments: {args}")

    try:
        # Build configuration
        config = ConfluenceConfig(
            base_url=args.url or "",
            email=args.email or "",
            api_token=args.token or "",
            space_key=args.space or ""
        )

        # Validate configuration
        missing = config.validate()
        if missing:
            logger.error(f"Missing required configuration: {', '.join(missing)}")
            if not args.quiet:
                print(f"Error: Missing required configuration: {', '.join(missing)}")
                print("Use --help for usage information")
            return 1

        # Parse labels
        labels = [l.strip() for l in args.labels.split(",") if l.strip()]

        # Create uploader and upload
        uploader = ConfluenceUploader(config)
        result = uploader.upload(
            file_path=args.file,
            title=args.title,
            labels=labels,
            parent_id=args.parent_id,
            update_existing=not args.no_update,
            use_code_block=not args.convert_markdown
        )

        # Output results
        if args.json:
            print(json.dumps(result, indent=2))
        elif not args.quiet:
            print(f"\n✅ Page {result['action']} successfully!")
            print(f"   Title: {result['title']}")
            print(f"   Page ID: {result['page_id']}")
            print(f"   URL: {result['page_url']}")

            if result['labels']:
                successful = [l['label'] for l in result['labels'] if l['success']]
                failed = [l['label'] for l in result['labels'] if not l['success']]

                if successful:
                    print(f"   Labels added: {', '.join(successful)}")
                if failed:
                    print(f"   Labels failed: {', '.join(failed)}")

        return 0

    except FileNotFoundError as e:
        logger.error(str(e))
        if not args.quiet:
            print(f"Error: {e}")
        return 1

    except ConfluenceAPIError as e:
        logger.error(f"Confluence API error: {e}")
        if not args.quiet:
            print(f"Error: {e}")
            if args.debug:
                print(f"Response: {e.response_body}")
        return 2

    except Exception as e:
        logger.exception(f"Unexpected error: {e}")
        if not args.quiet:
            print(f"Error: {e}")
        return 3


if __name__ == "__main__":
    sys.exit(main())
