defmodule AbyssalwatchWeb.LegacyRedirectController do
  @moduledoc """
  Permanent redirects from the pre-merge `/dashboard`, `/watchlists`, and
  `/notifications` routes into the unified `/watch` surface, translating the
  legacy query params to the new namespaced ones.

  See `AbyssalwatchWeb.WatchLive` for the URL contract.
  """
  use AbyssalwatchWeb, :controller

  def dashboard(conn, _params), do: redirect(conn, to: "/watch")

  def watchlists(conn, params) do
    redirect(conn, to: "/watch" <> watchlists_query(params))
  end

  def notifications(conn, params) do
    redirect(conn, to: "/watch" <> notifications_query(params))
  end

  defp watchlists_query(%{"action" => "new"} = params) do
    "?" <> URI.encode_query(maybe_seed_params(%{"new" => "1"}, params))
  end

  defp watchlists_query(%{"action" => "edit", "id" => id}) do
    "?" <> URI.encode_query(%{"wl" => id, "edit" => "1"})
  end

  defp watchlists_query(%{"id" => id}), do: "?" <> URI.encode_query(%{"wl" => id})
  defp watchlists_query(_), do: ""

  defp notifications_query(params) do
    pairs =
      []
      |> add_param(params, "filter", "show", &valid_show/1)
      |> add_param(params, "watchlist", "wl", &Function.identity/1)

    case pairs do
      [] -> ""
      _ -> "?" <> URI.encode_query(pairs)
    end
  end

  defp add_param(acc, params, legacy_key, new_key, transform) do
    case Map.get(params, legacy_key) do
      nil ->
        acc

      value ->
        case transform.(value) do
          nil -> acc
          ok -> [{new_key, ok} | acc]
        end
    end
  end

  defp valid_show(v) when v in ["all", "unread", "read"], do: v
  defp valid_show(_), do: nil

  # Forward optional ?type_id, ?max_price, ?min_score from the legacy
  # /watchlists?action=new deep links so the seeded form still picks them up.
  defp maybe_seed_params(base, params) do
    Enum.reduce(["type_id", "max_price", "min_score"], base, fn key, acc ->
      case Map.get(params, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end
end
