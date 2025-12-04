defmodule AbyssalwatchWeb.WellKnownController do
  @moduledoc """
  Handles .well-known requests to suppress noisy debug logs from browser probes.
  """
  use AbyssalwatchWeb, :controller

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> json(%{})
  end
end
