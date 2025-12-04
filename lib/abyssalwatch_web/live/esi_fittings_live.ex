defmodule AbyssalwatchWeb.ESIFittingsLive do
  @moduledoc """
  LiveView for importing character fittings from ESI.

  Allows authenticated users to:
  - View their EVE Online character fittings
  - Import fittings into AbyssalWatch
  - Use imported fittings in the optimization workflow
  """
  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Fittings.ESI.Client, as: ESIClient
  alias Abyssalwatch.Fittings.Fitting

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:fittings, [])
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> assign(:selected_fitting, nil)
     |> assign(:importing, false)
     |> start_fetch_fittings(user)}
  end

  @impl true
  def handle_info({:fittings_loaded, fittings}, socket) do
    {:noreply,
     socket
     |> assign(:fittings, fittings)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_info({:fittings_error, error}, socket) do
    {:noreply,
     socket
     |> assign(:error, error)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_info({:fitting_imported, fitting}, socket) do
    {:noreply,
     socket
     |> assign(:importing, false)
     |> put_flash(:info, "Fitting '#{fitting.name}' imported successfully!")
     |> push_navigate(to: ~p"/optimize")}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> assign(:error, nil)
     |> start_fetch_fittings(socket.assigns.current_user)}
  end

  @impl true
  def handle_event("select_fitting", %{"id" => fitting_id}, socket) do
    fitting =
      Enum.find(socket.assigns.fittings, &(&1.fitting_id == String.to_integer(fitting_id)))

    {:noreply, assign(socket, :selected_fitting, fitting)}
  end

  @impl true
  def handle_event("import_fitting", %{"id" => fitting_id}, socket) do
    fitting =
      Enum.find(socket.assigns.fittings, &(&1.fitting_id == String.to_integer(fitting_id)))

    if fitting do
      socket = assign(socket, :importing, true)

      # Import asynchronously
      pid = self()
      user = socket.assigns.current_user

      Task.start(fn ->
        case import_fitting(fitting, user) do
          {:ok, imported} ->
            send(pid, {:fitting_imported, imported})

          {:error, reason} ->
            send(pid, {:fittings_error, "Failed to import: #{inspect(reason)}"})
        end
      end)

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Fitting not found")}
    end
  end

  @impl true
  def handle_event("use_in_optimizer", %{"id" => fitting_id}, socket) do
    fitting =
      Enum.find(socket.assigns.fittings, &(&1.fitting_id == String.to_integer(fitting_id)))

    if fitting do
      # Store fitting in session for optimizer
      {:noreply,
       socket
       |> put_flash(:info, "Fitting selected for optimization")
       |> push_navigate(to: ~p"/optimize?esi_fitting_id=#{fitting_id}")}
    else
      {:noreply, put_flash(socket, :error, "Fitting not found")}
    end
  end

  # Private functions

  defp start_fetch_fittings(socket, user) do
    pid = self()

    Task.start(fn ->
      case ESIClient.ensure_valid_token(user) do
        {:ok, access_token, _updated_user} ->
          case ESIClient.get_fittings(user.character_id, access_token) do
            {:ok, fittings} ->
              # Enrich with ship names
              ship_type_ids = Enum.map(fittings, & &1.ship_type_id) |> Enum.uniq()

              enriched =
                case ESIClient.get_types(ship_type_ids) do
                  {:ok, types} ->
                    type_map = Map.new(types, fn t -> {t.id, t.name} end)

                    Enum.map(fittings, fn f ->
                      Map.put(f, :ship_name, Map.get(type_map, f.ship_type_id, "Unknown"))
                    end)

                  {:error, _} ->
                    fittings
                end

              send(pid, {:fittings_loaded, enriched})

            {:error, reason} ->
              send(pid, {:fittings_error, "Failed to fetch fittings: #{inspect(reason)}"})
          end

        {:error, reason} ->
          send(pid, {:fittings_error, "Token refresh failed: #{inspect(reason)}"})
      end
    end)

    socket
  end

  defp import_fitting(esi_fitting, user) do
    Ash.create(Fitting, %{esi_fitting: esi_fitting, user_id: user.id}, action: :from_esi)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <div class="flex justify-between items-center mb-6">
        <div>
          <h1 class="text-2xl font-bold">Your EVE Fittings</h1>
          <p class="text-gray-500">
            Import fittings from {@current_user.character_name}'s account
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-outline" disabled={@loading}>
          <%= if @loading do %>
            <span class="loading loading-spinner loading-sm"></span>
          <% else %>
            Refresh
          <% end %>
        </button>
      </div>

      <%= if @error do %>
        <div class="alert alert-error mb-4">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="stroke-current shrink-0 h-6 w-6"
            fill="none"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          <span>{@error}</span>
        </div>
      <% end %>

      <%= if @loading do %>
        <div class="flex justify-center items-center py-12">
          <span class="loading loading-spinner loading-lg"></span>
          <span class="ml-4">Loading your fittings from EVE Online...</span>
        </div>
      <% else %>
        <%= if @fittings == [] do %>
          <div class="text-center py-12">
            <p class="text-gray-500">No fittings found on your character.</p>
            <p class="text-sm text-gray-400 mt-2">
              Create fittings in EVE Online and they'll appear here.
            </p>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <%= for fitting <- @fittings do %>
              <div class={"card bg-base-100 shadow-md hover:shadow-lg transition-shadow cursor-pointer #{if @selected_fitting && @selected_fitting.fitting_id == fitting.fitting_id, do: "ring-2 ring-primary"}"}>
                <div class="card-body">
                  <h2 class="card-title text-lg">
                    {fitting.name}
                  </h2>
                  <p class="text-sm text-gray-500">
                    {fitting[:ship_name] || "Ship ##{fitting.ship_type_id}"}
                  </p>
                  <%= if fitting.description && fitting.description != "" do %>
                    <p class="text-xs text-gray-400 truncate">
                      {fitting.description}
                    </p>
                  <% end %>

                  <div class="card-actions justify-end mt-4">
                    <button
                      phx-click="use_in_optimizer"
                      phx-value-id={fitting.fitting_id}
                      class="btn btn-sm btn-primary"
                    >
                      Use in Optimizer
                    </button>
                    <button
                      phx-click="import_fitting"
                      phx-value-id={fitting.fitting_id}
                      class="btn btn-sm btn-outline"
                      disabled={@importing}
                    >
                      <%= if @importing do %>
                        <span class="loading loading-spinner loading-xs"></span>
                      <% else %>
                        Import
                      <% end %>
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
