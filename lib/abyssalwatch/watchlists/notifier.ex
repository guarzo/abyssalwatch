defmodule Abyssalwatch.Watchlists.Notifier do
  @moduledoc """
  Handles notification delivery via Phoenix.PubSub and Discord webhooks.

  Broadcasts notifications to user-specific channels so that
  connected LiveViews can receive real-time updates. Also dispatches
  Discord webhook notifications for users who have configured them.
  """

  require Logger

  alias Phoenix.PubSub
  alias Abyssalwatch.Accounts.NotificationSettings
  alias Abyssalwatch.Watchlists.Discord.{Client, MessageBuilder}

  @pubsub Abyssalwatch.PubSub

  @doc """
  Subscribe to notifications for a specific user.

  Call this in LiveView mount to receive real-time notifications.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(user_id) do
    PubSub.subscribe(@pubsub, user_topic(user_id))
  end

  @doc """
  Unsubscribe from notifications for a specific user.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(user_id) do
    PubSub.unsubscribe(@pubsub, user_topic(user_id))
  end

  @doc """
  Broadcast a new notification to a user.

  This is called by the Monitor when a new match is found.
  Also dispatches Discord notifications asynchronously if configured.
  """
  @spec broadcast_notification(String.t(), map(), map()) :: :ok | {:error, term()}
  def broadcast_notification(user_id, notification, watchlist) do
    payload = build_notification_payload(notification, watchlist)

    # Broadcast to PubSub for LiveView updates
    PubSub.broadcast(@pubsub, user_topic(user_id), {:new_notification, payload})

    # Send Discord notification asynchronously
    send_discord_notification_async(user_id, notification, watchlist)

    :ok
  end

  @doc """
  Send a Discord notification for a module match.

  This is called asynchronously via Task.Supervisor to avoid blocking
  the monitor process. Respects user notification settings including
  rate limiting and quiet hours.
  """
  @spec send_discord_notification(String.t(), map(), map()) :: :ok | {:error, term()}
  def send_discord_notification(user_id, notification, watchlist) do
    with {:ok, settings} <- get_notification_settings(user_id),
         true <- NotificationSettings.can_send_discord?(settings) do
      # Check score threshold
      score = notification.module_score || 0.0

      if score >= (settings.min_score_threshold || 0.0) do
        send_to_discord(settings, notification, watchlist)
      else
        Logger.debug("Skipping Discord notification: score #{score} below threshold")
        :ok
      end
    else
      {:ok, nil} ->
        Logger.debug("No notification settings found for user #{user_id}")
        :ok

      false ->
        Logger.debug("Discord notifications disabled or rate limited for user #{user_id}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed to get notification settings: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Broadcast when a notification is marked as read.
  """
  @spec broadcast_notification_read(String.t(), String.t()) :: :ok | {:error, term()}
  def broadcast_notification_read(user_id, notification_id) do
    PubSub.broadcast(@pubsub, user_topic(user_id), {:notification_read, notification_id})
  end

  @doc """
  Broadcast when all notifications are marked as read.
  """
  @spec broadcast_all_read(String.t()) :: :ok | {:error, term()}
  def broadcast_all_read(user_id) do
    PubSub.broadcast(@pubsub, user_topic(user_id), :all_notifications_read)
  end

  @doc """
  Broadcast when a notification is deleted.
  """
  @spec broadcast_notification_deleted(String.t(), String.t()) :: :ok | {:error, term()}
  def broadcast_notification_deleted(user_id, notification_id) do
    PubSub.broadcast(@pubsub, user_topic(user_id), {:notification_deleted, notification_id})
  end

  @doc """
  Broadcast a watchlist update to a user.

  This can be used to notify when a watchlist is updated, deleted, etc.
  """
  @spec broadcast_watchlist_update(String.t(), atom(), map()) :: :ok | {:error, term()}
  def broadcast_watchlist_update(user_id, action, watchlist) do
    payload = %{
      action: action,
      watchlist_id: watchlist.id,
      watchlist_name: watchlist.name,
      timestamp: DateTime.utc_now()
    }

    PubSub.broadcast(@pubsub, user_topic(user_id), {:watchlist_update, payload})
  end

  # Private functions

  defp user_topic(user_id) do
    "user:#{user_id}"
  end

  defp build_notification_payload(notification, watchlist) do
    %{
      id: notification.id,
      watchlist_id: watchlist.id,
      watchlist_name: watchlist.name,
      module_type_name: watchlist.module_type_name,
      module_external_id: notification.module_external_id,
      module_name: notification.module_name,
      module_price: notification.module_price,
      module_score: notification.module_score,
      sent_at: notification.sent_at,
      read: notification.read
    }
  end

  # Discord integration helpers

  defp send_discord_notification_async(user_id, notification, watchlist) do
    Task.Supervisor.start_child(
      Abyssalwatch.NotificationTasks,
      fn -> send_discord_notification(user_id, notification, watchlist) end
    )
  end

  defp get_notification_settings(user_id) do
    Ash.read_one(NotificationSettings, action: :for_user, args: %{user_id: user_id})
  end

  defp send_to_discord(settings, notification, watchlist) do
    opts = [
      mention_role_id: settings.discord_mention_role_id,
      include_details: settings.include_module_details
    ]

    payload = MessageBuilder.build_single_notification(notification, watchlist, opts)

    case Client.send_webhook(settings.discord_webhook_url, payload) do
      {:ok, _} ->
        # Increment the notification counter
        increment_discord_counter(settings)
        Logger.info("Discord notification sent for watchlist #{watchlist.name}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to send Discord notification: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp increment_discord_counter(settings) do
    Ash.update(settings, %{}, action: :increment_discord_count)
  end
end
