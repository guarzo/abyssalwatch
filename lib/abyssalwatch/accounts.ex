defmodule Abyssalwatch.Accounts do
  use Ash.Domain

  resources do
    resource(Abyssalwatch.Accounts.User)
    resource(Abyssalwatch.Accounts.Token)
    resource(Abyssalwatch.Accounts.NotificationSettings)
  end
end
