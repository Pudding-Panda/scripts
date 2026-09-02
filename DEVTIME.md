# devtime moved

The devtime tracker (heartbeat hook, Elixir server, report emails, dashboard) now lives in
its own repository, with its full history:

**git@git.puddi.ng:ppnd/devtime.git**

It was extracted on 2026-09-02 because the billing pipeline had grown past a scripts
directory: it is two deployed services, a Traefik/Authentik-gated dashboard at
`devtime-report.apps.puddi.ng`, and the source of the numbers on client invoices.

The heartbeat hook that every client session runs is the deployed copy at
`/opt/ppanda/scripts/devtime-hook.sh`; it is unaffected by this move. Update it from the new
repo, not from here.
