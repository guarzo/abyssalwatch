defmodule Abyssalwatch.Repo.Migrations.CreateNotificationSettings do
  @moduledoc """
  Phase 2: Creates the notification_settings table for user notification preferences.

  Stores Discord webhook configuration, rate limiting state, and notification preferences.
  """
  use Ecto.Migration

  def change do
    create table(:notification_settings, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false

      # User relationship
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      # Discord Configuration
      add :discord_webhook_url, :text
      add :discord_enabled, :boolean, default: false, null: false
      add :discord_mention_role_id, :string

      # Notification Preferences
      add :min_score_threshold, :float, default: 0.0
      add :max_notifications_per_hour, :integer, default: 10
      add :quiet_hours_start, :time
      add :quiet_hours_end, :time
      add :notify_on_price_drop, :boolean, default: true
      add :include_module_details, :boolean, default: true

      # Rate Limiting State
      add :discord_notifications_this_hour, :integer, default: 0
      add :discord_hour_window_start, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, inserted_at: :inserted_at, updated_at: :updated_at)
    end

    # One settings record per user (unique index also serves as lookup index)
    create unique_index(:notification_settings, [:user_id])
  end
end
