defmodule Abyssalwatch.Accounts.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        Abyssalwatch.Accounts.User,
        _opts,
        _context
      ) do
    case Application.fetch_env(:abyssalwatch, AbyssalwatchWeb.Endpoint) do
      {:ok, endpoint_config} ->
        Keyword.fetch(endpoint_config, :secret_key_base)

      :error ->
        :error
    end
  end
end
