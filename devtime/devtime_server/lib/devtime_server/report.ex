defmodule DevtimeServer.Report do
  # Grace window: a block stays open while the next query lands within @default_interval,
  # and every closed block gets a flat +@default_tolerance tail.
  @default_interval 30
  @default_tolerance 30
  # Local timezone offset (seconds) for day bucketing. BRT = UTC-3 = -10800.
  # Fixed offset (Brazil has no DST since 2019), so no tzdata dependency needed.
  @default_tz_offset -10800

  # Machine-generated heartbeats. A long-lived agent that re-prompts itself on a timer
  # fires UserPromptSubmit like a human would, so it must be filtered out or it merges
  # every block into a 24h day.
  @machine_event_types ~w(auto scheduled loop wakeup cron)
  # A chain of heartbeats whose gaps are all equal within this many seconds is a timer,
  # not a person. Chain members need not be consecutive: several monitors or crons on one
  # session interleave, so each timer is followed through the other beats.
  @default_cadence_tolerance 3
  # Minimum number of equal gaps (so min_run + 1 heartbeats) before a chain counts as a timer.
  @default_cadence_min_run 5
  # Periods outside this range are never treated as cadence.
  @min_cadence_s 300
  @max_cadence_s 3 * 3600

  def generate(opts \\ []) do
    days = Keyword.get(opts, :days, 7)
    interval = Keyword.get(opts, :interval, @default_interval)
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    client_filter = Keyword.get(opts, :client)
    user_filter = Keyword.get(opts, :user)
    exclude_machine = Keyword.get(opts, :exclude_machine, true)
    cadence_tolerance = Keyword.get(opts, :cadence_tolerance, @default_cadence_tolerance)
    cadence_min_run = Keyword.get(opts, :cadence_min_run, @default_cadence_min_run)

    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    cutoff = if from, do: trunc(from), else: System.system_time(:second) - days * 86400
    upper = if to, do: trunc(to), else: nil

    {sql, params} = build_query(cutoff, upper, client_filter, user_filter)
    {:ok, rows} = DevtimeServer.DB.query(sql, params)

    heartbeats = Enum.map(rows, fn [_id, _ts, ts_epoch, user, client, project, cwd, session_id, event_type] ->
      %{ts_epoch: ts_epoch, user: user, client: client, project: project, cwd: cwd, session_id: session_id, event_type: event_type}
    end)

    {heartbeats, machine_by_client} =
      if exclude_machine do
        drop_machine(heartbeats, cadence_tolerance, cadence_min_run)
      else
        {heartbeats, %{}}
      end

    by_client = Enum.group_by(heartbeats, & &1.client)
    interval_s = interval * 60
    tolerance_s = tolerance * 60
    tz_offset_s = tz_offset()

    daily = compute_daily(heartbeats, interval_s, tolerance_s, tz_offset_s)

    # Headline total = deduped wall-clock (per-day union of activity blocks across clients).
    # Per-client rows below can overlap and sum higher.
    wall_usage = Enum.reduce(daily, 0, fn {_day, dm}, acc -> acc + dm.total_seconds end)

    client_results =
      by_client
      |> Enum.map(fn {client, hbs} ->
        timestamps = hbs |> Enum.map(& &1.ts_epoch) |> Enum.sort()
        blocks = compute_blocks(timestamps, interval_s, tolerance_s)
        usage = Enum.reduce(blocks, 0.0, fn {s, e}, acc -> acc + (e - s) end)

        {client, %{
          total_seconds: round(usage),
          total_human: format_duration(usage),
          sessions: length(blocks),
          heartbeats: length(timestamps),
          machine_heartbeats: Map.get(machine_by_client, client, 0)
        }}
      end)
      |> Enum.sort_by(fn {_, v} -> -v.total_seconds end)
      |> Map.new()

    sum_client_usage = client_results |> Map.values() |> Enum.reduce(0, & &1.total_seconds + &2)

    client_results =
      Map.new(client_results, fn {k, v} ->
        share = if sum_client_usage > 0, do: Float.round(v.total_seconds / sum_client_usage * 100, 1), else: 0.0
        {k, Map.put(v, :share_pct, share)}
      end)

    %{
      period_days: days,
      interval_minutes: interval,
      tolerance_minutes: tolerance,
      tz_offset_seconds: tz_offset_s,
      exclude_machine: exclude_machine,
      cadence_tolerance_seconds: cadence_tolerance,
      cadence_min_run: cadence_min_run,
      machine_heartbeats_excluded: machine_by_client |> Map.values() |> Enum.sum(),
      machine_heartbeats_by_client: machine_by_client,
      from_epoch: cutoff,
      to_epoch: upper,
      total_seconds: round(wall_usage),
      total_human: format_duration(wall_usage),
      sum_client_usage_seconds: round(sum_client_usage),
      by_client: client_results,
      by_day: daily
    }
  end

  defp build_query(cutoff, upper, client_filter, user_filter) do
    base = "SELECT * FROM heartbeats WHERE ts_epoch >= ?1"
    params = [cutoff]
    {sql, params} =
      case upper do
        nil -> {base, params}
        u -> {base <> " AND ts_epoch <= ?#{length(params) + 1}", params ++ [u]}
      end
    {sql, params} =
      case client_filter do
        nil -> {sql, params}
        c -> {sql <> " AND client = ?#{length(params) + 1}", params ++ [c]}
      end
    {sql, params} =
      case user_filter do
        nil -> {sql, params}
        u -> {sql <> " AND user = ?#{length(params) + 1}", params ++ [u]}
      end
    {sql <> " ORDER BY ts_epoch ASC", params}
  end

  # Returns {kept_heartbeats, %{client => dropped_count}}. Drops heartbeats the emitter
  # already tagged as machine, then drops runs of fixed-cadence heartbeats (a timer-driven
  # agent re-prompting itself) that no human could produce.
  defp drop_machine(heartbeats, tolerance, min_run) do
    {tagged, rest} = Enum.split_with(heartbeats, &(&1.event_type in @machine_event_types))

    {kept, cadence_dropped} =
      rest
      |> Enum.group_by(& &1.client)
      |> Enum.reduce({[], %{}}, fn {client, hbs}, {kept, dropped} ->
        sorted = Enum.sort_by(hbs, & &1.ts_epoch)
        client_kept = drop_cadence_runs(sorted, tolerance, min_run)
        n = length(sorted) - length(client_kept)
        {client_kept ++ kept, if(n > 0, do: Map.put(dropped, client, n), else: dropped)}
      end)

    counts =
      Enum.reduce(tagged, cadence_dropped, fn hb, acc ->
        Map.update(acc, hb.client, 1, &(&1 + 1))
      end)

    {kept, counts}
  end

  defp drop_cadence_runs(hbs, _tolerance, _min_run) when length(hbs) < 2, do: hbs
  defp drop_cadence_runs(hbs, tolerance, min_run) do
    ts = hbs |> Enum.map(& &1.ts_epoch) |> List.to_tuple()
    machine = cadence_indices(ts, tolerance, min_run)

    hbs
    |> Enum.with_index()
    |> Enum.reject(fn {_hb, i} -> MapSet.member?(machine, i) end)
    |> Enum.map(&elem(&1, 0))
  end

  # For every pair (i, j) with a plausible timer period, follow the chain forward: the next
  # member is any heartbeat landing one period (the last gap, so slow drift is tracked)
  # after the previous one. Chains of at least min_run gaps mark all their members.
  defp cadence_indices(ts, tolerance, min_run) do
    n = tuple_size(ts)

    Enum.reduce(0..(n - 2), MapSet.new(), fn i, marked ->
      if MapSet.member?(marked, i) do
        marked
      else
        ti = elem(ts, i)

        (i + 1)..(n - 1)
        |> Enum.reduce_while(marked, fn j, acc ->
          d = elem(ts, j) - ti

          cond do
            d > @max_cadence_s ->
              {:halt, acc}

            d < @min_cadence_s ->
              {:cont, acc}

            true ->
              chain = follow_chain(ts, n, j, d, tolerance, [j, i])
              if length(chain) - 1 >= min_run, do: {:cont, MapSet.union(acc, MapSet.new(chain))}, else: {:cont, acc}
          end
        end)
      end
    end)
  end

  defp follow_chain(ts, n, last, d, tolerance, chain) do
    want = elem(ts, last) + d
    k = lower_bound(ts, want - tolerance, 0, n)

    if k < n and elem(ts, k) <= want + tolerance do
      follow_chain(ts, n, k, elem(ts, k) - elem(ts, last), tolerance, [k | chain])
    else
      chain
    end
  end

  defp lower_bound(_ts, _x, lo, hi) when lo >= hi, do: lo
  defp lower_bound(ts, x, lo, hi) do
    mid = div(lo + hi, 2)
    if elem(ts, mid) < x, do: lower_bound(ts, x, mid + 1, hi), else: lower_bound(ts, x, lo, mid)
  end

  defp compute_blocks([], _interval_s, _tolerance_s), do: []
  defp compute_blocks([first | rest], interval_s, tolerance_s) do
    {blocks, block_start, block_end} =
      Enum.reduce(rest, {[], first, first}, fn ts, {blocks, bs, be} ->
        if ts - be <= interval_s do
          {blocks, bs, ts}
        else
          {[{bs, be + tolerance_s} | blocks], ts, ts}
        end
      end)

    [{block_start, block_end + tolerance_s} | blocks] |> Enum.reverse()
  end

  defp tz_offset do
    case System.get_env("DEVTIME_TZ_OFFSET") do
      nil -> @default_tz_offset
      v ->
        case Integer.parse(v) do
          {n, _} -> n
          :error -> @default_tz_offset
        end
    end
  end

  defp compute_daily(heartbeats, interval_s, tolerance_s, tz_offset_s) do
    heartbeats
    |> Enum.group_by(fn hb ->
      # Bucket by LOCAL calendar day so a session's first->last span does not bleed
      # across the UTC midnight that falls inside the local working day.
      (trunc(hb.ts_epoch) + tz_offset_s)
      |> DateTime.from_unix!()
      |> DateTime.to_date()
      |> Date.to_iso8601()
    end)
    |> Enum.sort_by(fn {day, _} -> day end)
    |> Map.new(fn {day, hbs} ->
      by_client = Enum.group_by(hbs, & &1.client)
      client_data =
        Map.new(by_client, fn {client, chbs} ->
          timestamps = chbs |> Enum.map(& &1.ts_epoch) |> Enum.sort()
          blocks = compute_blocks(timestamps, interval_s, tolerance_s)
          usage = Enum.reduce(blocks, 0.0, fn {s, e}, acc -> acc + (e - s) end)
          {client, %{
            total_seconds: round(usage),
            total_human: format_duration(usage)
          }}
        end)

      # Per-day headline: deduped wall-clock across all clients (union of activity blocks).
      all_ts = hbs |> Enum.map(& &1.ts_epoch) |> Enum.sort()
      day_usage = compute_blocks(all_ts, interval_s, tolerance_s) |> Enum.reduce(0.0, fn {s, e}, acc -> acc + (e - s) end)
      {start_epoch, last_epoch} = Enum.min_max(all_ts)

      {day, %{
        clients: client_data,
        total_seconds: round(day_usage),
        total_human: format_duration(day_usage),
        start_epoch: trunc(start_epoch),
        end_epoch: trunc(last_epoch) + tolerance_s
      }}
    end)
  end

  defp format_duration(seconds) when is_float(seconds), do: format_duration(round(seconds))
  defp format_duration(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    if h > 0, do: "#{h}h #{String.pad_leading("#{m}", 2, "0")}m", else: "#{m}m"
  end
end
