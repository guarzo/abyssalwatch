defmodule Abyssalwatch.Accounts.NotificationSettings do
  @moduledoc """
  User notification preferences including Discord webhook configuration.

  Each user can have one NotificationSettings record that controls:
  - Discord webhook URL and whether Discord notifications are enabled
  - Rate limiting (max notifications per hour)
  - Quiet hours when notifications are suppressed
  - Minimum score threshold for notifications
  """
  use Ash.Resource,
    domain: Abyssalwatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("notification_settings")
    repo(Abyssalwatch.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    # Discord Configuration
    attribute :discord_webhook_url, :string do
      sensitive?(true)
      public?(true)
      description("Discord webhook URL for notifications")
    end

    attribute :discord_enabled, :boolean do
      default(false)
      public?(true)
      description("Whether Discord notifications are enabled")
    end

    attribute :discord_mention_role_id, :string do
      public?(true)
      description("Optional Discord role ID to @mention in notifications")
    end

    # Notification Preferences
    attribute :min_score_threshold, :float do
      default(0.0)
      public?(true)
      description("Only notify if module score >= threshold (0.0 = no minimum)")
    end

    attribute :max_notifications_per_hour, :integer do
      default(10)
      public?(true)
      description("Maximum notifications allowed per hour")
    end

    attribute :quiet_hours_start, :time do
      public?(true)
      description("Start of quiet hours (no notifications)")
    end

    attribute :quiet_hours_end, :time do
      public?(true)
      description("End of quiet hours")
    end

    attribute :notify_on_price_drop, :boolean do
      default(true)
      public?(true)
      description("Notify when a previously seen module drops in price")
    end

    attribute :include_module_details, :boolean do
      default(true)
      public?(true)
      description("Include full attribute details in notifications")
    end

    # Rate Limiting State (internal)
    attribute :discord_notifications_this_hour, :integer do
      default(0)
      description("Counter for rate limiting")
    end

    attribute :discord_hour_window_start, :utc_datetime_usec do
      description("Start of the current hour window for rate limiting")
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, Abyssalwatch.Accounts.User do
      allow_nil?(false)
      public?(true)
    end
  end

  identities do
    identity(:unique_user, [:user_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :discord_webhook_url,
        :discord_enabled,
        :discord_mention_role_id,
        :min_score_threshold,
        :max_notifications_per_hour,
        :quiet_hours_start,
        :quiet_hours_end,
        :notify_on_price_drop,
        :include_module_details
      ])

      argument(:user_id, :uuid, allow_nil?: false)
      change(manage_relationship(:user_id, :user, type: :append_and_remove))
    end

    update :update do
      primary?(true)

      accept([
        :discord_webhook_url,
        :discord_enabled,
        :discord_mention_role_id,
        :min_score_threshold,
        :max_notifications_per_hour,
        :quiet_hours_start,
        :quiet_hours_end,
        :notify_on_price_drop,
        :include_module_details
      ])
    end

    update :increment_discord_count do
      description("Increment the Discord notification counter, resetting if in a new hour")
      accept([])
      require_atomic?(false)

      change(fn changeset, _context ->
        now = DateTime.utc_now()
        current_window = Ash.Changeset.get_attribute(changeset, :discord_hour_window_start)

        current_count =
          Ash.Changeset.get_attribute(changeset, :discord_notifications_this_hour) || 0

        # Reset counter if we're in a new hour window
        if is_nil(current_window) or DateTime.diff(now, current_window, :hour) >= 1 do
          changeset
          |> Ash.Changeset.force_change_attribute(:discord_hour_window_start, now)
          |> Ash.Changeset.force_change_attribute(:discord_notifications_this_hour, 1)
        else
          Ash.Changeset.force_change_attribute(
            changeset,
            :discord_notifications_this_hour,
            current_count + 1
          )
        end
      end)
    end

    update :reset_discord_count do
      description("Reset the Discord notification counter")
      accept([])

      change(set_attribute(:discord_notifications_this_hour, 0))
      change(set_attribute(:discord_hour_window_start, nil))
    end

    read :for_user do
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id)))
      get?(true)
    end
  end

  validations do
    validate(
      match(:discord_webhook_url, ~r/^https:\/\/discord\.com\/api\/webhooks\/\d+\/[\w-]+$/),
      where: [present(:discord_webhook_url)],
      message: "must be a valid Discord webhook URL"
    )

    validate(
      numericality(:min_score_threshold,
        greater_than_or_equal_to: 0.0,
        less_than_or_equal_to: 1.0
      ),
      where: [present(:min_score_threshold)]
    )

    validate(
      numericality(:max_notifications_per_hour,
        greater_than_or_equal_to: 1,
        less_than_or_equal_to: 100
      ),
      where: [present(:max_notifications_per_hour)]
    )
  end

  @doc """
  Check if Discord notifications can be sent for this settings record.
  Returns true if enabled, has a webhook URL, not in quiet hours, and not rate limited.
  """
  def can_send_discord?(settings) when is_map(settings) do
    cond do
      not Map.get(settings, :discord_enabled, false) -> false
      is_nil(Map.get(settings, :discord_webhook_url)) -> false
      in_quiet_hours?(settings) -> false
      rate_limited?(settings) -> false
      true -> true
    end
  end

  def can_send_discord?(_), do: false

  @doc """
  Check if currently in quiet hours.
  """
  def in_quiet_hours?(%{quiet_hours_start: nil}), do: false
  def in_quiet_hours?(%{quiet_hours_end: nil}), do: false

  def in_quiet_hours?(%{quiet_hours_start: start_time, quiet_hours_end: end_time}) do
    current_time = DateTime.utc_now() |> DateTime.to_time()

    cond do
      # Normal case: start before end (e.g., 22:00 to 08:00)
      Time.compare(start_time, end_time) == :lt ->
        Time.compare(current_time, start_time) != :lt and
          Time.compare(current_time, end_time) == :lt

      # Overnight case: start after end (e.g., 22:00 to 08:00 next day)
      Time.compare(start_time, end_time) == :gt ->
        Time.compare(current_time, start_time) != :lt or
          Time.compare(current_time, end_time) == :lt

      # Start equals end - no quiet hours
      true ->
        false
    end
  end

  def in_quiet_hours?(_), do: false

  @doc """
  Check if rate limited for Discord notifications.
  """
  def rate_limited?(%{discord_hour_window_start: nil}), do: false

  def rate_limited?(settings) when is_map(settings) do
    now = DateTime.utc_now()
    window_start = Map.get(settings, :discord_hour_window_start)

    if is_nil(window_start) or DateTime.diff(now, window_start, :hour) >= 1 do
      # New hour window, not rate limited
      false
    else
      notifications_this_hour = Map.get(settings, :discord_notifications_this_hour, 0)
      max_per_hour = Map.get(settings, :max_notifications_per_hour, 10)
      notifications_this_hour >= max_per_hour
    end
  end

  def rate_limited?(_), do: false
end
