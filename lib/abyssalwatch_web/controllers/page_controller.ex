defmodule AbyssalwatchWeb.PageController do
  use AbyssalwatchWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/search")
  end
end
