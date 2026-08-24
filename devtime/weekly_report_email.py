#!/usr/bin/env python3
"""
Weekly devtime report emailer.
Pulls report from devtime server API, formats HTML email, sends via SendGrid SMTP.
Run via Jenkins cron or manually:
  python3 weekly_report_email.py [--days 7]
  python3 weekly_report_email.py --from 2026-05-25 --to 2026-06-01
  python3 weekly_report_email.py --all-weeks            # retroactive, one email per ISO week since conception

One metric is reported per client:
  Query usage - model query time: heartbeats merged while gaps stay within `interval`,
                each closed block gets a flat `tolerance` tail, longer idle gaps dropped.
"""

import argparse
import calendar
import json
import os
import smtplib
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import datetime, date, timedelta, timezone
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText


DEVTIME_URL = "http://127.0.0.1:7879/api/report"
TO_EMAIL = "rebecca@puddi.ng"


def get_smtp_creds():
    token = open(os.path.expanduser("/root/.op_service_account_token")).read().strip()
    env = {**os.environ, "OP_SERVICE_ACCOUNT_TOKEN": token}
    raw = subprocess.check_output(
        ["op", "item", "get", "PPD - SendGrid SMTP (puddi.ng)", "--vault", "ppanda/internal", "--fields", "notesPlain", "--reveal"],
        env=env,
    ).decode().strip().strip('"')
    # Parse API key from notes
    api_key = None
    for line in raw.split("\n"):
        if line.startswith("API Key: "):
            api_key = line.split("API Key: ", 1)[1].strip()
    return {
        "host": "smtp.sendgrid.net",
        "port": 587,
        "username": "apikey",
        "password": api_key,
        "from_email": "devtime@puddi.ng",
    }


def fetch_report(days=7, interval=30, tolerance=30, frm=None, to=None, exclude_machine=True):
    q = {"interval": interval, "tolerance": tolerance, "exclude_machine": 1 if exclude_machine else 0}
    if frm is not None:
        q["from"] = int(frm)
        if to is not None:
            q["to"] = int(to)
    else:
        q["days"] = days
    url = f"{DEVTIME_URL}?{urllib.parse.urlencode(q)}"
    with urllib.request.urlopen(url, timeout=15) as resp:
        return json.loads(resp.read())


def _hm(seconds):
    h = seconds // 3600
    m = (seconds % 3600) // 60
    return f"{h}h {m:02d}m" if h > 0 else f"{m}m"


def _hhmm(epoch, offset):
    return datetime.fromtimestamp(epoch + offset, timezone.utc).strftime("%H:%M")


def format_html(report, start, end):
    clients = report["by_client"]
    daily = report["by_day"]

    rows = ""
    for client, data in sorted(clients.items(), key=lambda x: -x[1]["total_seconds"]):
        rows += f"""<tr>
            <td style="padding:6px 12px;border-bottom:1px solid #eee;font-weight:bold">{client}</td>
            <td style="padding:6px 12px;border-bottom:1px solid #eee;text-align:right;font-weight:bold;color:#6c5ce7">{data['total_human']}</td>
            <td style="padding:6px 12px;border-bottom:1px solid #eee;text-align:right">{data['heartbeats']}</td>
            <td style="padding:6px 12px;border-bottom:1px solid #eee;text-align:right">{data['share_pct']}%</td>
        </tr>"""

    off = report.get("tz_offset_seconds", 0)
    machine = report.get("machine_heartbeats_excluded", 0)
    machine_by = report.get("machine_heartbeats_by_client", {})
    machine_note = ""
    if machine:
        detail = ", ".join(f"{c}: {n}" for c, n in sorted(machine_by.items(), key=lambda x: -x[1]))
        machine_note = (f"<p style=\"font-size:12px;color:#b26b00;background:#fff8e6;padding:8px 12px;"
                        f"border-left:3px solid #f0a500;margin:12px 0\">"
                        f"{machine} machine heartbeat(s) excluded ({detail}) — timer-driven agent prompts, "
                        f"not human activity.</p>")

    daily_rows = ""
    for day in sorted(daily.keys()):
        dd = daily[day]
        day_clients = dd["clients"]
        day_use = dd["total_seconds"]
        day_start = _hhmm(dd["start_epoch"], off)
        end_local = datetime.fromtimestamp(dd["end_epoch"] + off, timezone.utc)
        day_end = end_local.strftime("%H:%M")
        if end_local.date().isoformat() > day:
            day_end += " (ND)"
        parts = sorted(day_clients.items(), key=lambda x: -x[1]["total_seconds"])
        breakdown = ", ".join(f"{c}: {d['total_human']}" for c, d in parts)
        daily_rows += f"""<tr>
            <td style="padding:4px 12px;border-bottom:1px solid #eee">{day}</td>
            <td style="padding:4px 12px;border-bottom:1px solid #eee;text-align:right;font-variant-numeric:tabular-nums">{day_start}</td>
            <td style="padding:4px 12px;border-bottom:1px solid #eee;text-align:right;font-variant-numeric:tabular-nums">{day_end}</td>
            <td style="padding:4px 12px;border-bottom:1px solid #eee;text-align:right;font-weight:bold">{_hm(day_use)}</td>
            <td style="padding:4px 12px;border-bottom:1px solid #eee;font-size:13px;color:#666">{breakdown}</td>
        </tr>"""

    return f"""<html><body style="font-family:-apple-system,Helvetica,Arial,sans-serif;color:#333;max-width:760px;margin:0 auto">
    <h2 style="color:#2d3436;border-bottom:2px solid #6c5ce7;padding-bottom:8px">
        Developer Time Report — {start.strftime('%b %d')} to {end.strftime('%b %d, %Y')}
    </h2>

    <p style="font-size:22px;font-weight:bold;color:#6c5ce7">Query usage: {report['total_human']}</p>

    <p style="font-size:12px;color:#888;margin-top:-8px">
        <b>Query usage</b> = model query time. Queries merge into one block while each gap stays
        within {report['interval_minutes']}m; a block ends {report['tolerance_minutes']}m after its last query, and longer idle gaps count as nothing.
        Top-line is deduped wall-clock; per-client rows can overlap (same dev across clients in a day) so they sum higher.
    </p>
    {machine_note}

    <table style="border-collapse:collapse;width:100%;margin:16px 0">
        <tr style="background:#f8f9fa">
            <th style="padding:8px 12px;text-align:left">Client</th>
            <th style="padding:8px 12px;text-align:right">Query usage</th>
            <th style="padding:8px 12px;text-align:right">Heartbeats</th>
            <th style="padding:8px 12px;text-align:right">Share</th>
        </tr>
        {rows}
    </table>

    <h3 style="color:#2d3436;margin-top:24px">Daily Breakdown</h3>
    <table style="border-collapse:collapse;width:100%;margin:16px 0">
        <tr style="background:#f8f9fa">
            <th style="padding:6px 12px;text-align:left">Date</th>
            <th style="padding:6px 12px;text-align:right">Start</th>
            <th style="padding:6px 12px;text-align:right">End</th>
            <th style="padding:6px 12px;text-align:right">Query usage</th>
            <th style="padding:6px 12px;text-align:left">Clients (query usage)</th>
        </tr>
        {daily_rows}
    </table>

    <p style="font-size:12px;color:#999;margin-top:24px;border-top:1px solid #eee;padding-top:8px">
        Generated by devtime-server on jenkins.puddi.ng
        &middot; interval={report['interval_minutes']}m, tolerance={report['tolerance_minutes']}m
        &middot; days/times in UTC{off // 3600:+d}
        &middot; machine heartbeats {'excluded' if report.get('exclude_machine', True) else 'INCLUDED'}
        &middot; <a href="https://devtime.apps.puddi.ng" style="color:#6c5ce7">Wakapi Dashboard</a>
    </p>
</body></html>"""


def send_email(html, subject, smtp_creds):
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = smtp_creds["from_email"]
    msg["To"] = TO_EMAIL
    msg.attach(MIMEText(html, "html"))

    with smtplib.SMTP(smtp_creds["host"], int(smtp_creds["port"])) as server:
        server.starttls()
        server.login(smtp_creds["username"], smtp_creds["password"])
        server.sendmail(smtp_creds["from_email"], [TO_EMAIL], msg.as_string())


def subject_for(report, start, end, tag=""):
    prefix = f"{tag} " if tag else ""
    return (f"{prefix}Devtime Report: {start.strftime('%b %d')}–{end.strftime('%b %d')} "
            f"— Usage {report['total_human']}")


def deliver(report, start, end, dry_run, smtp_creds, preview_path, tag=""):
    html = format_html(report, start, end)
    subject = subject_for(report, start, end, tag)
    if dry_run:
        print(f"[dry-run] {subject}  (clients={len(report['by_client'])})")
        with open(preview_path, "w") as f:
            f.write(html)
        print(f"          preview: {preview_path}")
        return
    send_email(html, subject, smtp_creds)
    print(f"Sent: {subject}")


def iso_weeks_since(first_day):
    """Yield (start_dt, end_dt) UTC for each Mon..Sun week from first_day's week to now."""
    d = date.fromisoformat(first_day)
    monday = d - timedelta(days=d.weekday())
    ws = datetime(monday.year, monday.month, monday.day)
    now = datetime.now(timezone.utc).replace(tzinfo=None)
    while ws <= now:
        we = ws + timedelta(days=7)
        yield ws, we
        ws = we


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--interval", type=int, default=30)
    parser.add_argument("--tolerance", type=int, default=30)
    parser.add_argument("--from", dest="frm", help="window start, YYYY-MM-DD (UTC)")
    parser.add_argument("--to", dest="to", help="window end, YYYY-MM-DD (UTC)")
    parser.add_argument("--all-weeks", action="store_true", help="send one report per ISO week since conception")
    parser.add_argument("--tag", default="", help="subject-line prefix, e.g. [corrected]")
    parser.add_argument("--include-machine", action="store_true",
                        help="keep timer-driven agent heartbeats (audit / pre-fix comparison)")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    exclude_machine = not args.include_machine

    smtp_creds = None if args.dry_run else get_smtp_creds()

    if args.all_weeks:
        # Earliest day = min key of a wide-window report.
        big = fetch_report(days=400, interval=args.interval, tolerance=args.tolerance,
                           exclude_machine=exclude_machine)
        if not big["by_day"]:
            print("No heartbeats found.")
            return
        first_day = min(big["by_day"].keys())
        print(f"Conception: {first_day}. Building weekly reports...")
        sent = 0
        for ws, we in iso_weeks_since(first_day):
            frm = calendar.timegm(ws.timetuple())
            to = calendar.timegm(we.timetuple()) - 1
            report = fetch_report(interval=args.interval, tolerance=args.tolerance, frm=frm, to=to,
                                  exclude_machine=exclude_machine)
            if report["total_seconds"] == 0:
                print(f"[skip empty] {ws.date()}–{(we - timedelta(days=1)).date()}")
                continue
            deliver(report, ws, we - timedelta(days=1), args.dry_run, smtp_creds,
                    f"/tmp/devtime-week-{ws.date()}.html", args.tag)
            sent += 1
        print(f"Done. {sent} weekly reports {'previewed' if args.dry_run else 'sent'}.")
        return

    if args.frm:
        start = datetime.fromisoformat(args.frm)
        end = datetime.fromisoformat(args.to) if args.to else datetime.now(timezone.utc).replace(tzinfo=None)
        frm = calendar.timegm(start.timetuple())
        to = calendar.timegm(end.timetuple())
        report = fetch_report(interval=args.interval, tolerance=args.tolerance, frm=frm, to=to,
                              exclude_machine=exclude_machine)
    else:
        end = datetime.now()
        start = end - timedelta(days=args.days)
        report = fetch_report(days=args.days, interval=args.interval, tolerance=args.tolerance,
                              exclude_machine=exclude_machine)

    deliver(report, start, end, args.dry_run, smtp_creds, "/tmp/devtime-report-preview.html", args.tag)


if __name__ == "__main__":
    main()
