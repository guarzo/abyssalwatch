defmodule Abyssalwatch.Watchlists do
  @moduledoc """
  The Watchlists domain manages user watchlists and notifications.

  Watchlists allow users to define criteria for abyssal modules they want
  to monitor. When modules matching those criteria appear on the market,
  notifications are generated and delivered in real-time via PubSub.
  """
  use Ash.Domain

  resources do
    resource(Abyssalwatch.Watchlists.Watchlist)
    resource(Abyssalwatch.Watchlists.Notification)
  end
end
