defmodule Abyssalwatch.Watchlists.Discord.Client do
  @moduledoc """
  HTTP client for Discord webhook API.

  Sends notification messages to Discord channels via webhooks.
  Handles rate limiting, retries, and error responses.

  Discord Webhook Rate Limits:
  - 30 requests per minute per webhook
  - 429 responses include Retry-After header

  Reference: https://discord.com/developers/docs/resources/webhook
  """

  require Logger

  @max_retries 3
  @base_retry_delay 1_000

  @type webhook_result :: {:ok, map()} | {:error, term()}

  @doc """
  Send a message to a Discord webhook.

  ## Options
    - `:wait` - Wait for server confirmation (default: true)
    - `:thread_id` - Send to a specific thread within the channel
  """
  @spec send_webhook(String.t(), map(), keyword()) :: webhook_result()
  def send_webhook(webhook_url, payload, opts \\ []) do
    wait = Keyword.get(opts, :wait, true)
    thread_id = Keyword.get(opts, :thread_id)

    url = build_url(webhook_url, wait, thread_id)

    do_send_webhook(url, payload, 0)
  end

  defp do_send_webhook(url, payload, attempt) when attempt < @max_retries do
    case Req.post(url, json: payload, headers: headers()) do
      {:ok, %{status: status, body: body}} when status in [200, 204] ->
        Logger.debug("Discord webhook sent successfully")
        {:ok, body}

      {:ok, %{status: 429, headers: headers}} ->
        # Rate limited - extract retry-after and wait
        retry_after = get_retry_after(headers)
        Logger.warning("Discord rate limited, retrying after #{retry_after}ms")
        Process.sleep(retry_after)
        do_send_webhook(url, payload, attempt + 1)

      {:ok, %{status: status, body: body}} when status >= 400 ->
        Logger.error("Discord webhook failed: #{status} - #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("Discord webhook request failed: #{inspect(reason)}")
        # Retry with exponential backoff for network errors
        Process.sleep(backoff_delay(attempt))
        do_send_webhook(url, payload, attempt + 1)
    end
  end

  defp do_send_webhook(_url, _payload, _attempt) do
    Logger.error("Discord webhook failed after #{@max_retries} retries")
    {:error, :max_retries_exceeded}
  end

  defp build_url(webhook_url, wait, thread_id) do
    params = []
    params = if wait, do: [{"wait", "true"} | params], else: params
    params = if thread_id, do: [{"thread_id", thread_id} | params], else: params

    case params do
      [] -> webhook_url
      _ -> "#{webhook_url}?#{URI.encode_query(params)}"
    end
  end

  defp headers do
    [
      {"content-type", "application/json"},
      {"user-agent", "AbyssalWatch/1.0 (Elixir; EVE Online Abyssal Module Tracker)"}
    ]
  end

  defp get_retry_after(headers) do
    headers = headers |> Enum.into(%{})

    case Map.get(headers, "retry-after") do
      nil ->
        @base_retry_delay

      value when is_binary(value) ->
        case Float.parse(value) do
          {seconds, _} -> round(seconds * 1000)
          :error -> @base_retry_delay
        end

      value when is_number(value) ->
        round(value * 1000)
    end
  end

  defp backoff_delay(attempt) do
    # Exponential backoff: 1s, 2s, 4s
    round(@base_retry_delay * :math.pow(2, attempt))
  end

  @doc """
  Validate a Discord webhook URL format.
  """
  @spec valid_webhook_url?(String.t()) :: boolean()
  def valid_webhook_url?(url) when is_binary(url) do
    Regex.match?(~r/^https:\/\/discord\.com\/api\/webhooks\/\d+\/[\w-]+$/, url)
  end

  def valid_webhook_url?(_), do: false

  @doc """
  Test a webhook by sending a test message.
  Returns {:ok, :valid} if successful, {:error, reason} otherwise.
  """
  @spec test_webhook(String.t()) :: {:ok, :valid} | {:error, term()}
  def test_webhook(webhook_url) do
    test_payload = %{
      content: nil,
      embeds: [
        %{
          title: "AbyssalWatch Connected",
          description:
            "This Discord channel will now receive watchlist notifications from AbyssalWatch.",
          color: 0x00FF00,
          fields: [
            %{
              name: "Status",
              value: "Webhook test successful",
              inline: true
            },
            %{
              name: "Timestamp",
              value: DateTime.utc_now() |> DateTime.to_iso8601(),
              inline: true
            }
          ],
          footer: %{
            text: "AbyssalWatch - EVE Online Abyssal Module Tracker"
          },
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      ]
    }

    case send_webhook(webhook_url, test_payload) do
      {:ok, _} -> {:ok, :valid}
      error -> error
    end
  end
end
