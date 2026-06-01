defmodule DevtimeServer.Report do
  @default_interval 60
  @default_tolerance 30
  # Local timezone offset (seconds) for day bucketing. BRT = UTC-3 = -10800.
  # Fixed offset (Brazil has no DST since 2019), so no tzdata dependency needed.
  @default_tz_offset -10800

  def generate(opts \\ []) do
    days = Keyword.get(opts, :days, 7)
    interval = Keyword.get(opts, :interval, @default_interval)
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    client_filter = Keyword.get(opts, :client)
    user_filter = Keyword.get(opts, :user)

    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)
    cutoff = if from, do: trunc(from), else: System.system_time(:second) - days * 86400
    upper = if to, do: trunc(to), else: nil

    {sql, params} = build_query(cutoff, upper, client_filter, user_filter)
    {:ok, rows} = DevtimeServer.DB.query(sql, params)

    heartbeats = Enum.map(rows, fn [_id, _ts, ts_epoch, user, client, project, cwd, session_id, event_type] ->
      %{ts_epoch: ts_epoch, user: user, client: client, project: project, cwd: cwd, session_id: session_id, event_type: event_type}
    end)

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
          heartbeats: length(timestamps)
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
