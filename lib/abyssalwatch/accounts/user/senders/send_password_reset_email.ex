defmodule Abyssalwatch.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email.
  """
  use AshAuthentication.Sender

  @impl true
  def send(user, token, _opts) do
    # For now, just log the reset token
    # In production, you'd send an actual email
    require Logger
    Logger.info("Password reset requested for #{user.email}. Token: #{token}")
    :ok
  end
end
