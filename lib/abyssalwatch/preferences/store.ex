defmodule Abyssalwatch.Preferences.Store do
  @moduledoc """
  ETS-based storage for user preferences and recent searches.

  For Phase 1 (anonymous access), preferences are stored with a session token
  that's generated when a user first visits the site. Preferences persist
  for the duration of the browser session.
  """

  use GenServer

  @table_name :preferences_store
  @max_recent_searches 10
  @cleanup_interval :timer.hours(24)
  @preference_ttl :timer.hours(72)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get recent searches for a session.
  Returns a list of recent search maps, newest first.
  """
  def get_recent_searches(session_id) when is_binary(session_id) do
    case :ets.lookup(@table_name, {:searches, session_id}) do
      [{_, searches, _expires_at}] -> searches
      [] -> []
    end
  end

  def get_recent_searches(_), do: []

  @doc """
  Add a search to recent searches for a session.
  Stores the search with deduplication (same type_id updates the existing entry).
  """
  def add_recent_search(session_id, search) when is_binary(session_id) and is_map(search) do
    GenServer.cast(__MODULE__, {:add_search, session_id, search})
  end

  def add_recent_search(_, _), do: :ok

  @doc """
  Clear recent searches for a session.
  """
  def clear_recent_searches(session_id) when is_binary(session_id) do
    :ets.delete(@table_name, {:searches, session_id})
    :ok
  end

  def clear_recent_searches(_), do: :ok

  @doc """
  Get a preference value for a session.
  """
  def get_preference(session_id, key, default \\ nil) when is_binary(session_id) do
    case :ets.lookup(@table_name, {:pref, session_id, key}) do
      [{_, value, _expires_at}] -> value
      [] -> default
    end
  end

  @doc """
  Set a preference value for a session.
  """
  def set_preference(session_id, key, value) when is_binary(session_id) do
    expires_at = System.monotonic_time(:millisecond) + @preference_ttl
    :ets.insert(@table_name, {{:pref, session_id, key}, value, expires_at})
    :ok
  end

  @doc """
  Generate a unique session ID if one doesn't exist.
  """
  def generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table_name, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:add_search, session_id, search}, state) do
    searches = get_recent_searches(session_id)

    # Normalize the search data
    search_data = %{
      type_id: search[:type_id] || search["type_id"],
      type_name: search[:type_name] || search["type_name"],
      preset: search[:preset] || search["preset"] || "default",
      result_count: search[:result_count] || search["result_count"] || 0,
      searched_at: DateTime.utc_now()
    }

    # Remove duplicate (same type_id) if exists
    searches =
      Enum.reject(searches, fn s ->
        s.type_id == search_data.type_id
      end)

    # Add new search at the beginning and limit to max
    searches = [search_data | searches] |> Enum.take(@max_recent_searches)

    # Store with expiration
    expires_at = System.monotonic_time(:millisecond) + @preference_ttl
    :ets.insert(@table_name, {{:searches, session_id}, searches, expires_at})

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn {_key, _value, expires_at} = entry, acc ->
        if expires_at < now do
          :ets.delete_object(@table_name, entry)
        end

        acc
      end,
      :ok,
      @table_name
    )
  end
end
