defmodule AbyssalwatchWeb.PageControllerTest do
  use AbyssalwatchWeb.ConnCase

  test "GET / redirects to /search", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/search"
  end
end
