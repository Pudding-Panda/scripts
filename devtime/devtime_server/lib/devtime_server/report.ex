defmodule DevtimeServer.Report do
  @default_interval 60
  @default_tolerance 30
  # Local timezone offset (seconds) for day bucketing. BRT = UTC-3 = -10800.
  # Fixed offset (Brazil has no DST since 2019), so no tzdata dependency needed.
  @default_tz_offset -10800

  # Machine-generated heartbeats. A long-lived agent that re-prompts itself on a timer
  # fires UserPromptSubmit like a human would, so it must be filtered out or it merges
  # every block into a 24h day.
  @machine_event_types ~w(auto scheduled loop wakeup cron)
  # A run of consecutive heartbeats whose gaps are all equal within this many seconds
  # is a timer, not a person.
  @default_cadence_tolerance 5
  # Minimum number of equal gaps (so min_run + 1 heartbeats) before a run counts as a timer.
  @default_cadence_min_run 3
  # Gaps shorter than this are human bursts; never treat them as cadence.
  @min_cadence_s 300

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

    # Per-client engagement = sum of that client's per-day (last - first) + tolerance.
    # These overlap when one dev multiplexes clients in a day, so they are NOT summed
    # into the headline total (that would exceed wall-clock).
    engagement_by_client =
      Enum.reduce(daily, %{}, fn {_day, dm}, acc ->
        Enum.reduce(dm.clients, acc, fn {client, m}, acc2 ->
          Map.update(acc2, client, m.engagement_seconds, &(&1 + m.engagement_seconds))
        end)
      end)

    # Headline totals = deduped wall-clock (per-day union across clients), so Active and
    # Usage share one basis. Per-client rows below can overlap and sum higher.
    wall_engagement = Enum.reduce(daily, 0, fn {_day, dm}, acc -> acc + dm.engagement_seconds end)
    wall_usage = Enum.reduce(daily, 0, fn {_day, dm}, acc -> acc + dm.total_seconds end)

    client_results =
      by_client
      |> Enum.map(fn {client, hbs} ->
        timestamps = hbs |> Enum.map(& &1.ts_epoch) |> Enum.sort()
        blocks = compute_blocks(timestamps, interval_s, tolerance_s)
        usage = Enum.reduce(blocks, 0.0, fn {s, e}, acc -> acc + (e - s) end)
        engagement = Map.get(engagement_by_client, client, 0)

        {client, %{
          total_seconds: round(usage),
          total_human: format_duration(usage),
          engagement_seconds: round(engagement),
          engagement_human: format_duration(engagement),
          sessions: length(blocks),
          heartbeats: length(timestamps),
          machine_heartbeats: Map.get(machine_by_client, client, 0)
        }}
      end)
      |> Enum.sort_by(fn {_, v} -> -v.engagement_seconds end)
      |> Map.new()

    sum_client_usage = client_results |> Map.values() |> Enum.reduce(0, & &1.total_seconds + &2)
    sum_client_engagement = client_results |> Map.values() |> Enum.reduce(0, & &1.engagement_seconds + &2)

    client_results =
      Map.new(client_results, fn {k, v} ->
        share = if sum_client_usage > 0, do: Float.round(v.total_seconds / sum_client_usage * 100, 1), else: 0.0
        eshare = if sum_client_engagement > 0, do: Float.round(v.engagement_seconds / sum_client_engagement * 100, 1), else: 0.0
        {k, v |> Map.put(:share_pct, share) |> Map.put(:engagement_share_pct, eshare)}
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
      engagement_seconds: round(wall_engagement),
      engagement_human: format_duration(wall_engagement),
      sum_client_usage_seconds: round(sum_client_usage),
      engagement_by_client_seconds: round(sum_client_engagement),
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
    timestamps = Enum.map(hbs, & &1.ts_epoch)
    deltas = Enum.zip(timestamps, tl(timestamps)) |> Enum.map(fn {a, b} -> b - a end)
    machine = cadence_indices(deltas, tolerance, min_run)

    hbs
    |> Enum.with_index()
    |> Enum.reject(fn {_hb, i} -> MapSet.member?(machine, i) end)
    |> Enum.map(&elem(&1, 0))
  end

  # Delta i sits between heartbeat i and heartbeat i+1, so a run of equal deltas
  # marks every heartbeat it touches.
  defp cadence_indices(deltas, tolerance, min_run) do
    {runs, current} =
      deltas
      |> Enum.with_index()
      |> Enum.reduce({[], nil}, fn {delta, i}, {runs, current} ->
        cond do
          delta < @min_cadence_s ->
            {close_run(runs, current, min_run), nil}

          current == nil ->
            {runs, {delta, [i]}}

          true ->
            {head, idxs} = current

            if abs(delta - head) <= tolerance do
              {runs, {head, [i | idxs]}}
            else
              {close_run(runs, current, min_run), {delta, [i]}}
            end
        end
      end)

    close_run(runs, current, min_run)
    |> Enum.reduce(MapSet.new(), fn idxs, acc ->
      Enum.reduce(idxs, acc, fn i, set -> set |> MapSet.put(i) |> MapSet.put(i + 1) end)
    end)
  end

  defp close_run(runs, nil, _min_run), do: runs
  defp close_run(runs, {_head, idxs}, min_run) do
    if length(idxs) >= min_run, do: [idxs | runs], else: runs
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

  defp engagement_span([], _tolerance_s), do: 0.0
  defp engagement_span(timestamps, tolerance_s) do
    {min, max} = Enum.min_max(timestamps)
    (max - min) + tolerance_s
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
          engagement = engagement_span(timestamps, tolerance_s)
          {client, %{
            total_seconds: round(usage),
            total_human: format_duration(usage),
            engagement_seconds: round(engagement),
            engagement_human: format_duration(engagement)
          }}
        end)

      # Per-day headline: deduped wall-clock across all clients (union span for engagement,
      # union of activity blocks for usage).
      all_ts = hbs |> Enum.map(& &1.ts_epoch) |> Enum.sort()
      day_engagement = engagement_span(all_ts, tolerance_s)
      day_usage = compute_blocks(all_ts, interval_s, tolerance_s) |> Enum.reduce(0.0, fn {s, e}, acc -> acc + (e - s) end)
      {start_epoch, last_epoch} = Enum.min_max(all_ts)

      {day, %{
        clients: client_data,
        engagement_seconds: round(day_engagement),
        engagement_human: format_duration(day_engagement),
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
