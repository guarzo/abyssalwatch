defmodule Abyssalwatch.Market.Mutamarket.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for Mutamarket API requests.
  Allows 5 requests/second with a burst of 10.
  """
  use GenServer

  @default_rate 5
  @default_burst 10
  @refill_interval 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Acquire a token to make an API request.
  Returns :ok if a token is available, {:error, :rate_limited} otherwise.
  """
  def acquire(timeout \\ 5_000) do
    GenServer.call(__MODULE__, :acquire, timeout)
  end

  @doc """
  Acquire a token, waiting if necessary.
  Blocks until a token is available.
  """
  def acquire_blocking(max_wait \\ 10_000) do
    case acquire() do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        if max_wait > 0 do
          Process.sleep(200)
          acquire_blocking(max_wait - 200)
        else
          {:error, :rate_limited}
        end
    end
  end

  @doc """
  Get current token count (for monitoring).
  """
  def tokens do
    GenServer.call(__MODULE__, :tokens)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    rate = Keyword.get(opts, :rate, @default_rate)
    burst = Keyword.get(opts, :burst, @default_burst)

    schedule_refill()

    {:ok,
     %{
       tokens: burst,
       rate: rate,
       burst: burst
     }}
  end

  @impl true
  def handle_call(:acquire, _from, %{tokens: 0} = state) do
    {:reply, {:error, :rate_limited}, state}
  end

  def handle_call(:acquire, _from, %{tokens: tokens} = state) do
    {:reply, :ok, %{state | tokens: tokens - 1}}
  end

  def handle_call(:tokens, _from, state) do
    {:reply, state.tokens, state}
  end

  @impl true
  def handle_info(:refill, %{tokens: tokens, rate: rate, burst: burst} = state) do
    new_tokens = min(tokens + rate, burst)
    schedule_refill()
    {:noreply, %{state | tokens: new_tokens}}
  end

  defp schedule_refill do
    Process.send_after(self(), :refill, @refill_interval)
  end
end
