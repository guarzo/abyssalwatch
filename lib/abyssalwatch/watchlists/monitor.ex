defmodule Abyssalwatch.Watchlists.Monitor do
  @moduledoc """
  Background GenServer that periodically checks watchlists for matching modules.

  The monitor runs on a configurable interval (default: 10 minutes) and:
  1. Fetches all active watchlists (notifications_enabled = true)
  2. For each unique module type, fetches available modules from Mutamarket
  3. Runs the matching logic against each watchlist
  4. Creates notifications for new matches (deduped within 24 hours)
  5. Broadcasts notifications via PubSub for real-time UI updates
  """

  use GenServer
  require Logger

  alias Abyssalwatch.Watchlists.{Matcher, Notifier, Watchlist, Notification}
  alias Abyssalwatch.Market.Mutamarket.Client, as: MutamarketClient
  alias Abyssalwatch.Market.Scoring.{Topsis, Criteria}

  # Default check interval: 10 minutes
  @default_check_interval :timer.minutes(10)
  # Maximum concurrent watchlist processing
  @max_concurrent 5

  # Client API

  @doc """
  Start the monitor process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger an immediate check of all watchlists.
  Useful for testing or manual triggering.
  """
  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  @doc """
  Check a specific watchlist immediately.
  """
  def check_watchlist(watchlist_id) do
    GenServer.cast(__MODULE__, {:check_watchlist, watchlist_id})
  end

  @doc """
  Get the current status of the monitor.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Pause the monitor (stops automatic checks).
  """
  def pause do
    GenServer.cast(__MODULE__, :pause)
  end

  @doc """
  Resume the monitor after pausing.
  """
  def resume do
    GenServer.cast(__MODULE__, :resume)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    check_interval = Keyword.get(opts, :check_interval, @default_check_interval)
    auto_start = Keyword.get(opts, :auto_start, true)

    state = %{
      check_interval: check_interval,
      last_check: nil,
      next_check: nil,
      stats: %{
        total_checks: 0,
        total_matches: 0,
        last_error: nil
      },
      paused: false,
      timer_ref: nil
    }

    state =
      if auto_start do
        # Schedule first check after a short delay to let the system stabilize
        schedule_check(state, :timer.seconds(30))
      else
        state
      end

    Logger.info("Watchlist Monitor started with #{div(check_interval, 60_000)} minute interval")

    {:ok, state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    if state.paused do
      {:noreply, state}
    else
      state = cancel_scheduled_check(state)
      new_state = perform_check(state)
      {:noreply, schedule_check(new_state)}
    end
  end

  @impl true
  def handle_cast({:check_watchlist, watchlist_id}, state) do
    Task.start(fn ->
      process_single_watchlist(watchlist_id)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("Watchlist Monitor paused")
    state = cancel_scheduled_check(state)
    {:noreply, %{state | paused: true}}
  end

  @impl true
  def handle_cast(:resume, state) do
    Logger.info("Watchlist Monitor resumed")
    new_state = %{state | paused: false}
    {:noreply, schedule_check(new_state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      paused: state.paused,
      last_check: state.last_check,
      next_check: state.next_check,
      check_interval_minutes: div(state.check_interval, 60_000),
      stats: state.stats
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:check_watchlists, state) do
    if state.paused do
      {:noreply, state}
    else
      new_state = perform_check(state)
      {:noreply, schedule_check(new_state)}
    end
  end

  # Private Functions

  defp schedule_check(state, delay \\ nil) do
    delay = delay || state.check_interval
    timer_ref = Process.send_after(self(), :check_watchlists, delay)
    next_check = DateTime.add(DateTime.utc_now(), div(delay, 1000), :second)

    %{state | timer_ref: timer_ref, next_check: next_check}
  end

  defp cancel_scheduled_check(state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    %{state | timer_ref: nil, next_check: nil}
  end

  defp perform_check(state) do
    Logger.info("Starting watchlist check...")
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        active_watchlists = list_active_watchlists()
        Logger.info("Found #{length(active_watchlists)} active watchlists")

        # Group watchlists by module_type_id for efficient API calls
        watchlists_by_type = Enum.group_by(active_watchlists, & &1.module_type_id)

        total_matches =
          watchlists_by_type
          |> Task.async_stream(
            fn {type_id, watchlists} ->
              process_watchlists_for_type(type_id, watchlists)
            end,
            max_concurrency: @max_concurrent,
            timeout: 60_000
          )
          |> Enum.reduce(0, fn
            {:ok, match_count}, acc ->
              acc + match_count

            {:exit, reason}, acc ->
              Logger.error("Watchlist processing task failed: #{inspect(reason)}")
              acc
          end)

        {:ok, total_matches}
      rescue
        e ->
          Logger.error("Error during watchlist check: #{Exception.message(e)}")
          {:error, e}
      end

    elapsed = System.monotonic_time(:millisecond) - start_time
    Logger.info("Watchlist check completed in #{elapsed}ms")

    update_stats(state, result)
  end

  defp list_active_watchlists do
    case Ash.read(Watchlist, action: :active) do
      {:ok, watchlists} -> watchlists
      {:error, _} -> []
    end
  end

  defp process_watchlists_for_type(type_id, watchlists) do
    Logger.debug("Checking #{length(watchlists)} watchlists for type #{type_id}")

    # Fetch modules for this type from Mutamarket
    case MutamarketClient.search_modules(type_id) do
      {:ok, raw_modules} when is_list(raw_modules) and length(raw_modules) > 0 ->
        # Score the modules using TOPSIS
        scored_modules = Topsis.score(raw_modules, Criteria.default())

        # Process each watchlist
        watchlists
        |> Enum.map(fn watchlist -> process_watchlist(watchlist, scored_modules) end)
        |> Enum.sum()

      {:ok, _} ->
        Logger.debug("No modules found for type #{type_id}")
        0

      {:error, reason} ->
        Logger.warning("Failed to fetch modules for type #{type_id}: #{inspect(reason)}")
        0
    end
  end

  defp process_watchlist(watchlist, modules) do
    # Find matching modules
    matches = Matcher.find_matches(modules, watchlist)

    # Process each match
    match_count =
      matches
      |> Enum.map(fn match -> create_notification_if_new(match) end)
      |> Enum.count(& &1)

    # Update watchlist stats
    if match_count > 0 do
      update_watchlist_checked(watchlist)
    end

    match_count
  end

  defp process_single_watchlist(watchlist_id) do
    case Ash.get(Watchlist, watchlist_id, action: :get_by_id) do
      {:ok, watchlist} ->
        case MutamarketClient.search_modules(watchlist.module_type_id) do
          {:ok, raw_modules} when is_list(raw_modules) ->
            scored_modules = Topsis.score(raw_modules, Criteria.default())
            process_watchlist(watchlist, scored_modules)

          _ ->
            0
        end

      {:error, _} ->
        0
    end
  end

  defp create_notification_if_new(%{module: module, watchlist: watchlist}) do
    external_id = module[:external_id] || module["external_id"]

    # Check for duplicate notification in the last 24 hours
    case check_duplicate_notification(watchlist.id, external_id) do
      {:ok, nil} ->
        # No recent notification exists, create one
        create_notification(watchlist, module)
        true

      {:ok, _existing} ->
        # Duplicate found, skip
        false

      {:error, _} ->
        false
    end
  end

  defp check_duplicate_notification(watchlist_id, module_external_id) do
    Ash.read_one(Notification,
      action: :check_duplicate,
      args: %{watchlist_id: watchlist_id, module_external_id: module_external_id}
    )
  end

  defp create_notification(watchlist, module) do
    external_id = module[:external_id] || module["external_id"]
    name = module[:name] || module["name"]
    price = module[:price] || module["price"]
    score = module[:score] || module["score"]
    attributes = module[:attributes] || module["attributes"] || %{}

    case Ash.create(Notification, %{
           user_id: watchlist.user_id,
           watchlist_id: watchlist.id,
           module_external_id: external_id,
           module_name: name,
           module_price: price,
           module_score: score,
           module_attributes: attributes
         }) do
      {:ok, notification} ->
        # Broadcast the notification via PubSub
        Notifier.broadcast_notification(watchlist.user_id, notification, watchlist)

        # Update watchlist match count
        update_watchlist_match_count(watchlist)

        Logger.info("Created notification for user #{watchlist.user_id}: #{name}")
        {:ok, notification}

      {:error, reason} ->
        Logger.warning("Failed to create notification: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp update_watchlist_checked(watchlist) do
    Ash.update(watchlist, %{}, action: :mark_checked)
  end

  defp update_watchlist_match_count(watchlist) do
    Ash.update(watchlist, %{}, action: :increment_match_count)
  end

  defp update_stats(state, {:ok, match_count}) do
    %{
      state
      | last_check: DateTime.utc_now(),
        stats: %{
          state.stats
          | total_checks: state.stats.total_checks + 1,
            total_matches: state.stats.total_matches + match_count,
            last_error: nil
        }
    }
  end

  defp update_stats(state, {:error, error}) do
    %{
      state
      | last_check: DateTime.utc_now(),
        stats: %{
          state.stats
          | total_checks: state.stats.total_checks + 1,
            last_error: Exception.message(error)
        }
    }
  end
end
