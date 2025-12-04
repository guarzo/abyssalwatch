defmodule Abyssalwatch.Market.Mutamarket.Cache do
  @moduledoc """
  ETS-based cache for Mutamarket API responses.
  Implements TTL-based expiration (default 24 hours).
  """
  use GenServer

  @table_name :mutamarket_cache
  @default_ttl :timer.hours(24)
  @cleanup_interval :timer.minutes(15)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a cached value by key.
  Returns {:ok, value} if found and not expired, :miss otherwise.
  """
  def get(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, value}
        else
          delete(key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Put a value in the cache with optional TTL.
  """
  def put(key, value, ttl \\ @default_ttl) do
    expires_at = System.monotonic_time(:millisecond) + ttl
    :ets.insert(@table_name, {key, value, expires_at})
    :ok
  end

  @doc """
  Delete a cached value.
  """
  def delete(key) do
    :ets.delete(@table_name, key)
    :ok
  end

  @doc """
  Clear all cached values.
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Get cache stats.
  """
  def stats do
    %{
      size: :ets.info(@table_name, :size),
      memory: :ets.info(@table_name, :memory)
    }
  end

  @doc """
  Get all non-expired cache entries as {key, value} tuples.
  """
  def all_entries do
    now = System.monotonic_time(:millisecond)

    :ets.foldl(
      fn {key, value, expires_at}, acc ->
        if expires_at > now do
          [{key, value} | acc]
        else
          acc
        end
      end,
      [],
      @table_name
    )
  rescue
    _ -> []
  end

  @doc """
  Fetch from cache or execute function and cache result.
  """
  def fetch(key, ttl \\ @default_ttl, fun) do
    case get(key) do
      {:ok, value} ->
        {:ok, value, :cached}

      :miss ->
        case fun.() do
          {:ok, value} ->
            put(key, value, ttl)
            {:ok, value, :fresh}

          error ->
            error
        end
    end
  end

  # Server callbacks

  @impl true
  def init(opts) do
    table =
      :ets.new(@table_name, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_cleanup()

    {:ok, %{table: table, ttl: Keyword.get(opts, :ttl, @default_ttl)}}
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

    # Find and delete expired entries
    :ets.foldl(
      fn {key, _value, expires_at}, acc ->
        if expires_at < now do
          :ets.delete(@table_name, key)
        end

        acc
      end,
      :ok,
      @table_name
    )
  end
end
