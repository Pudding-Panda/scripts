#!/usr/bin/env python3
"""
Monthly devtime report emailer.
One email per month: per-client weekly breakdown plus the month total.
  python3 monthly_report_email.py --month 2026-08
  python3 monthly_report_email.py --month 2026-08 --dry-run

Weeks are Mon-Sun, clipped to the month. Days and week boundaries are local
(UTC-3), matching the day bucketing of the devtime server.
"""

import argparse
import calendar
import json
import urllib.parse
import urllib.request
from datetime import datetime, date, timedelta, timezone

from weekly_report_email import get_smtp_creds, send_email, DEVTIME_URL

TZ_OFFSET = -10800


def fetch(frm, to, interval, tolerance, exclude_machine=True):
    q = {"interval": interval, "tolerance": tolerance,
         "exclude_machine": 1 if exclude_machine else 0,
         "from": int(frm), "to": int(to)}
    url = f"{DEVTIME_URL}?{urllib.parse.urlencode(q)}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.loads(resp.read())


def epoch(d):
    return calendar.timegm(datetime(d.year, d.month, d.day).timetuple()) - TZ_OFFSET


def weeks_of(first, last):
    """Mon-Sun weeks clipped to [first, last]."""
    out = []
    ws = first
    while ws <= last:
        we = min(ws + timedelta(days=6 - ws.weekday()), last)
        out.append((ws, we))
        ws = we + timedelta(days=1)
    return out


def _hm(seconds):
    h = seconds // 3600
    m = (seconds % 3600) // 60
    return f"{h}h {m:02d}m" if h > 0 else f"{m}m"


def format_html(month_label, first, last, month, weeks):
    clients = sorted(month["by_client"], key=lambda c: -month["by_client"][c]["total_seconds"])

    head = "".join(
        f'<th style="padding:8px 10px;text-align:right;font-size:12px">{ws.strftime("%b %d")}'
        f'<span style="color:#999">&ndash;{we.strftime("%d")}</span></th>'
        for ws, we, _ in weeks)

    rows = ""
    for c in clients:
        cells = ""
        for _, _, rep in weeks:
            secs = rep["by_client"].get(c, {}).get("total_seconds", 0)
            style = "color:#ccc" if secs == 0 else ""
            cells += (f'<td style="padding:6px 10px;border-bottom:1px solid #eee;text-align:right;'
                      f'font-variant-numeric:tabular-nums;{style}">{_hm(secs) if secs else "-"}</td>')
        m = month["by_client"][c]
        rows += f"""<tr>
            <td style="padding:6px 12px;border-bottom:1px solid #eee;font-weight:bold">{c}</td>
            {cells}
            <td style="padding:6px 12px;border-bottom:1px solid #eee;text-align:right;font-weight:bold;color:#6c5ce7">{m['total_human']}</td>
            <td style="padding:6px 12px;border-bottom:1px solid #eee;text-align:right;color:#888">{m['share_pct']}%</td>
        </tr>"""

    week_totals = "".join(
        f'<td style="padding:8px 10px;text-align:right;font-weight:bold;'
        f'font-variant-numeric:tabular-nums">{_hm(rep["total_seconds"])}</td>'
        for _, _, rep in weeks)

    machine = month.get("machine_heartbeats_excluded", 0)
    machine_note = ""
    if machine:
        detail = ", ".join(f"{c}: {n}" for c, n in
                           sorted(month.get("machine_heartbeats_by_client", {}).items(), key=lambda x: -x[1]))
        machine_note = (f'<p style="font-size:12px;color:#b26b00;background:#fff8e6;padding:8px 12px;'
                        f'border-left:3px solid #f0a500;margin:12px 0">'
                        f'{machine} machine heartbeat(s) excluded ({detail}) &mdash; timer-driven agent prompts, '
                        f'not human activity.</p>')

    sum_clients = month.get("sum_client_usage_seconds", 0)

    return f"""<html><body style="font-family:-apple-system,Helvetica,Arial,sans-serif;color:#333;max-width:860px;margin:0 auto">
    <h2 style="color:#2d3436;border-bottom:2px solid #6c5ce7;padding-bottom:8px">
        Developer Time Report &mdash; {month_label}
    </h2>

    <p style="font-size:22px;font-weight:bold;color:#6c5ce7">Query usage: {month['total_human']}</p>

    <p style="font-size:12px;color:#888;margin-top:-8px">
        {first.isoformat()} to {last.isoformat()}.
        <b>Query usage</b> = model query time. Queries merge into one block while each gap stays
        within {month['interval_minutes']}m; a block ends {month['tolerance_minutes']}m after its last query, and longer idle gaps
        count as nothing. The headline is deduped wall-clock; per-client rows can overlap
        (same dev across clients in a day) and sum to {_hm(sum_clients)}.
    </p>
    {machine_note}

    <table style="border-collapse:collapse;width:100%;margin:16px 0">
        <tr style="background:#f8f9fa">
            <th style="padding:8px 12px;text-align:left">Client</th>
            {head}
            <th style="padding:8px 12px;text-align:right">Month</th>
            <th style="padding:8px 12px;text-align:right">Share</th>
        </tr>
        {rows}
        <tr style="background:#f8f9fa">
            <td style="padding:8px 12px;font-weight:bold">All (deduped)</td>
            {week_totals}
            <td style="padding:8px 12px;text-align:right;font-weight:bold;color:#6c5ce7">{month['total_human']}</td>
            <td style="padding:8px 12px"></td>
        </tr>
    </table>

    <p style="font-size:12px;color:#999;margin-top:24px;border-top:1px solid #eee;padding-top:8px">
        Generated by devtime-server on jenkins.puddi.ng
        &middot; interval={month['interval_minutes']}m, tolerance={month['tolerance_minutes']}m
        &middot; weeks Mon&ndash;Sun clipped to the month, days/times in UTC-3
        &middot; machine heartbeats {'excluded' if month.get('exclude_machine', True) else 'INCLUDED'}
        &middot; <a href="https://devtime.apps.puddi.ng" style="color:#6c5ce7">Wakapi Dashboard</a>
    </p>
</body></html>"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--month", required=True, help="YYYY-MM")
    parser.add_argument("--interval", type=int, default=30)
    parser.add_argument("--tolerance", type=int, default=30)
    parser.add_argument("--tag", default="")
    parser.add_argument("--include-machine", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    exclude_machine = not args.include_machine

    year, mon = (int(x) for x in args.month.split("-"))
    first = date(year, mon, 1)
    last = date(year, mon, calendar.monthrange(year, mon)[1])
    today = datetime.now(timezone.utc).date()
    if last > today:
        last = today

    month = fetch(epoch(first), epoch(last + timedelta(days=1)) - 1,
                  args.interval, args.tolerance, exclude_machine)

    weeks = []
    for ws, we in weeks_of(first, last):
        rep = fetch(epoch(ws), epoch(we + timedelta(days=1)) - 1,
                    args.interval, args.tolerance, exclude_machine)
        weeks.append((ws, we, rep))

    label = first.strftime("%B %Y")
    html = format_html(label, first, last, month, weeks)
    subject = f"{args.tag + ' ' if args.tag else ''}Devtime Report: {label} — Usage {month['total_human']}"

    if args.dry_run:
        path = f"/tmp/devtime-month-{args.month}.html"
        with open(path, "w") as f:
            f.write(html)
        print(f"[dry-run] {subject}")
        print(f"          preview: {path}")
        for ws, we, rep in weeks:
            print(f"          {ws} to {we}: {rep['total_human']}")
        return

    send_email(html, subject, get_smtp_creds())
    print(f"Sent: {subject}")


if __name__ == "__main__":
    main()
