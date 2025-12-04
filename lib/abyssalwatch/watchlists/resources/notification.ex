defmodule Abyssalwatch.Watchlists.Notification do
  @moduledoc """
  Records notifications sent when modules match watchlist criteria.

  Notifications are deduplicated within a 24-hour window to prevent
  spam when the same module keeps matching the same watchlist.
  """
  use Ash.Resource,
    domain: Abyssalwatch.Watchlists,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("notifications")
    repo(Abyssalwatch.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :module_external_id, :string do
      allow_nil?(false)
      public?(true)
      description("External ID of the matched module")
    end

    attribute :module_name, :string do
      public?(true)
      description("Name of the matched module")
    end

    attribute :module_price, :decimal do
      public?(true)
      description("Price of the module at notification time")
    end

    attribute :module_score, :float do
      public?(true)
      description("TOPSIS score of the module at notification time")
    end

    attribute :module_attributes, :map do
      default(%{})
      public?(true)
      description("Module attributes at notification time")
    end

    attribute :read, :boolean do
      default(false)
      public?(true)
      description("Whether the notification has been read")
    end

    attribute :sent_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
      description("When the notification was sent")
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :user, Abyssalwatch.Accounts.User do
      allow_nil?(false)
      public?(true)
    end

    belongs_to :watchlist, Abyssalwatch.Watchlists.Watchlist do
      allow_nil?(false)
      public?(true)
    end
  end

  identities do
    # Prevent duplicate notifications for the same module/watchlist combo within a time window
    # This is checked programmatically in the matcher, but we also have a unique constraint
    identity(:unique_recent_notification, [:watchlist_id, :module_external_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :module_external_id,
        :module_name,
        :module_price,
        :module_score,
        :module_attributes
      ])

      argument(:user_id, :uuid, allow_nil?: false)
      argument(:watchlist_id, :uuid, allow_nil?: false)

      change(manage_relationship(:user_id, :user, type: :append_and_remove))
      change(manage_relationship(:watchlist_id, :watchlist, type: :append_and_remove))
      change(set_attribute(:sent_at, &DateTime.utc_now/0))
    end

    update :mark_read do
      accept([])
      change(set_attribute(:read, true))
    end

    update :mark_unread do
      accept([])
      change(set_attribute(:read, false))
    end

    action :mark_all_read_for_user, :integer do
      description(
        "Bulk mark all unread notifications as read for a user. Returns count of updated notifications."
      )

      argument(:user_id, :uuid, allow_nil?: false)

      run(fn input, _context ->
        user_id = input.arguments.user_id

        # Use Ecto directly for efficient bulk update
        import Ecto.Query

        result =
          Abyssalwatch.Repo.update_all(
            from(n in "notifications",
              where: n.user_id == ^user_id and n.read == false
            ),
            set: [read: true, updated_at: DateTime.utc_now()]
          )

        case result do
          {count, _} -> {:ok, count}
          _ -> {:ok, 0}
        end
      end)
    end

    read :for_user do
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id)))
      prepare(build(sort: [sent_at: :desc]))
    end

    read :unread_for_user do
      argument(:user_id, :uuid, allow_nil?: false)
      filter(expr(user_id == ^arg(:user_id) and read == false))
      prepare(build(sort: [sent_at: :desc]))
    end

    read :for_watchlist do
      argument(:watchlist_id, :uuid, allow_nil?: false)
      filter(expr(watchlist_id == ^arg(:watchlist_id)))
      prepare(build(sort: [sent_at: :desc]))
    end

    read :for_user_and_watchlist do
      description("Get notifications for a user filtered by watchlist")
      argument(:user_id, :uuid, allow_nil?: false)
      argument(:watchlist_id, :uuid, allow_nil?: false)

      filter(expr(user_id == ^arg(:user_id) and watchlist_id == ^arg(:watchlist_id)))
      prepare(build(sort: [sent_at: :desc]))
    end

    read :recent do
      description("Returns notifications from the last 24 hours")
      argument(:user_id, :uuid, allow_nil?: false)

      filter(
        expr(
          user_id == ^arg(:user_id) and
            sent_at > ago(24, :hour)
        )
      )

      prepare(build(sort: [sent_at: :desc]))
    end

    read :check_duplicate do
      description("Check if a notification for this module/watchlist exists in the last 24 hours")
      argument(:watchlist_id, :uuid, allow_nil?: false)
      argument(:module_external_id, :string, allow_nil?: false)

      filter(
        expr(
          watchlist_id == ^arg(:watchlist_id) and
            module_external_id == ^arg(:module_external_id) and
            sent_at > ago(24, :hour)
        )
      )

      get?(true)
    end

    read :get_by_id do
      argument(:id, :uuid, allow_nil?: false)
      filter(expr(id == ^arg(:id)))
      get?(true)
    end
  end

  calculations do
    calculate :time_ago, :string do
      calculation(fn records, _context ->
        now = DateTime.utc_now()

        Enum.map(records, fn record ->
          diff = DateTime.diff(now, record.sent_at, :second)

          cond do
            diff < 60 -> "just now"
            diff < 3600 -> "#{div(diff, 60)} minutes ago"
            diff < 86400 -> "#{div(diff, 3600)} hours ago"
            true -> "#{div(diff, 86400)} days ago"
          end
        end)
      end)
    end
  end
end
