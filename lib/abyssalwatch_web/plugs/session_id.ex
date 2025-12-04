defmodule AbyssalwatchWeb.Plugs.SessionId do
  @moduledoc """
  Plug to ensure a session has a unique preference session ID.

  This plug generates a unique session ID if one doesn't exist,
  allowing us to track preferences across page loads for Phase 1
  anonymous users.
  """

  import Plug.Conn

  @session_key "abyssalwatch_session_id"

  def init(opts), do: opts

  def call(conn, _opts) do
    session_id = get_session(conn, @session_key)

    if session_id do
      assign(conn, :session_id, session_id)
    else
      new_session_id = Abyssalwatch.Preferences.Store.generate_session_id()

      conn
      |> put_session(@session_key, new_session_id)
      |> assign(:session_id, new_session_id)
    end
  end
end
