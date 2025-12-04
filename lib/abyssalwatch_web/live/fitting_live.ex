defmodule AbyssalwatchWeb.FittingLive do
  @moduledoc """
  LiveView for viewing fittings from shareable URLs.

  This handles the `/fit/:dna` route, allowing users to view fittings
  shared via DNA URLs or in-game links.
  """
  use AbyssalwatchWeb, :live_view

  alias Abyssalwatch.Fittings.Parsers.{DNA, EFT}
  alias Abyssalwatch.Fittings.ESI.Client, as: ESIClient

  @impl true
  def mount(%{"dna" => encoded_dna}, _session, socket) do
    dna = URI.decode(encoded_dna)

    case DNA.parse(dna) do
      {:ok, parsed} ->
        {:ok,
         socket
         |> assign(:dna, dna)
         |> assign(:fitting, parsed)
         |> assign(:ship_name, nil)
         |> assign(:loading_names, true)
         |> assign(:error, nil)
         |> start_name_resolution(parsed)}

      {:error, reason} ->
        {:ok,
         socket
         |> assign(:dna, dna)
         |> assign(:fitting, nil)
         |> assign(:error, reason)}
    end
  end

  @impl true
  def handle_info({:names_resolved, ship_name, module_names}, socket) do
    fitting = socket.assigns.fitting

    enriched_fitting =
      if fitting do
        %{
          fitting
          | high_slots: enrich_modules(fitting.high_slots, module_names),
            med_slots: enrich_modules(fitting.med_slots, module_names),
            low_slots: enrich_modules(fitting.low_slots, module_names),
            rig_slots: enrich_modules(fitting.rig_slots, module_names)
        }
      else
        fitting
      end

    {:noreply,
     socket
     |> assign(:fitting, enriched_fitting)
     |> assign(:ship_name, ship_name)
     |> assign(:loading_names, false)}
  end

  @impl true
  def handle_event("copy_eft", _params, socket) do
    eft_text = generate_eft(socket.assigns)

    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: eft_text})
     |> put_flash(:info, "Copied EFT format to clipboard")}
  end

  @impl true
  def handle_event("copy_ingame_link", _params, socket) do
    link = DNA.to_ingame_link(socket.assigns.fitting, socket.assigns.ship_name || "Imported Fit")

    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: link})
     |> put_flash(:info, "Copied in-game link to clipboard")}
  end

  @impl true
  def handle_event("copy_share_url", _params, socket) do
    url = DNA.to_share_url(socket.assigns.fitting)

    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: url})
     |> put_flash(:info, "Copied share URL to clipboard")}
  end

  # Private functions

  defp start_name_resolution(socket, parsed) do
    # Collect all type IDs that need resolution
    type_ids =
      [parsed.ship_type_id] ++
        Enum.flat_map(parsed.high_slots || [], & &1.type_id) ++
        Enum.flat_map(parsed.med_slots || [], & &1.type_id) ++
        Enum.flat_map(parsed.low_slots || [], & &1.type_id) ++
        Enum.flat_map(parsed.rig_slots || [], & &1.type_id)

    type_ids = type_ids |> List.flatten() |> Enum.uniq()

    # Resolve names asynchronously
    pid = self()

    Task.start(fn ->
      case ESIClient.get_types(type_ids) do
        {:ok, names} ->
          name_map = Map.new(names, fn n -> {n.id, n.name} end)
          ship_name = Map.get(name_map, parsed.ship_type_id, "Unknown Ship")
          send(pid, {:names_resolved, ship_name, name_map})

        {:error, _} ->
          send(pid, {:names_resolved, "Unknown Ship", %{}})
      end
    end)

    socket
  end

  defp enrich_modules(modules, name_map) when is_list(modules) do
    Enum.map(modules, fn mod ->
      Map.put(mod, :name, Map.get(name_map, mod.type_id, "Type #{mod.type_id}"))
    end)
  end

  defp enrich_modules(modules, _), do: modules

  defp generate_eft(assigns) do
    fitting = assigns.fitting
    ship_name = assigns.ship_name || "Unknown Ship"

    EFT.encode(%{
      name: "Imported Fit",
      ship_type: ship_name,
      low_slots: fitting.low_slots || [],
      med_slots: fitting.med_slots || [],
      high_slots: fitting.high_slots || [],
      rig_slots: fitting.rig_slots || [],
      subsystems: fitting.subsystems || [],
      drones: fitting.drones || [],
      cargo: fitting.cargo || []
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto px-4 py-8">
      <%= if @error do %>
        <div class="alert alert-error">
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
          <span>Invalid fitting: {@error}</span>
        </div>
      <% else %>
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <!-- Header -->
            <div class="flex justify-between items-start">
              <div>
                <h1 class="card-title text-2xl">
                  <%= if @loading_names do %>
                    <span class="loading loading-spinner loading-sm"></span> Loading...
                  <% else %>
                    {@ship_name || "Ship Fitting"}
                  <% end %>
                </h1>
                <p class="text-gray-500 text-sm">Ship Type ID: {@fitting.ship_type_id}</p>
              </div>
              <div class="flex gap-2">
                <button phx-click="copy_eft" class="btn btn-sm btn-outline">
                  Copy EFT
                </button>
                <button phx-click="copy_ingame_link" class="btn btn-sm btn-outline">
                  Copy In-Game Link
                </button>
                <button phx-click="copy_share_url" class="btn btn-sm btn-primary">
                  Copy Share URL
                </button>
              </div>
            </div>

            <div class="divider"></div>
            
    <!-- Fitting Layout -->
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              <!-- High Slots -->
              <.slot_section
                title="High Slots"
                modules={@fitting.high_slots}
                loading={@loading_names}
              />
              
    <!-- Med Slots -->
              <.slot_section
                title="Medium Slots"
                modules={@fitting.med_slots}
                loading={@loading_names}
              />
              
    <!-- Low Slots -->
              <.slot_section
                title="Low Slots"
                modules={@fitting.low_slots}
                loading={@loading_names}
              />
              
    <!-- Rig Slots -->
              <.slot_section
                title="Rig Slots"
                modules={@fitting.rig_slots}
                loading={@loading_names}
              />
              
    <!-- Drones -->
              <%= if @fitting.drones && @fitting.drones != [] do %>
                <.slot_section
                  title="Drones"
                  modules={@fitting.drones}
                  loading={@loading_names}
                />
              <% end %>
              
    <!-- Cargo -->
              <%= if @fitting.cargo && @fitting.cargo != [] do %>
                <.slot_section
                  title="Cargo"
                  modules={@fitting.cargo}
                  loading={@loading_names}
                />
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>

    <script>
      window.addEventListener("phx:copy_to_clipboard", (e) => {
        navigator.clipboard.writeText(e.detail.text);
      });
    </script>
    """
  end

  defp slot_section(assigns) do
    ~H"""
    <div class="bg-base-200 rounded-lg p-4">
      <h3 class="font-semibold mb-2">{@title}</h3>
      <%= if @modules && @modules != [] do %>
        <ul class="space-y-1">
          <%= for mod <- @modules do %>
            <li class="text-sm flex justify-between">
              <span>
                <%= if @loading do %>
                  Type {mod.type_id}
                <% else %>
                  {mod[:name] || "Type #{mod.type_id}"}
                <% end %>
              </span>
              <%= if mod.quantity > 1 do %>
                <span class="badge badge-sm">x{mod.quantity}</span>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% else %>
        <p class="text-sm text-gray-500">Empty</p>
      <% end %>
    </div>
    """
  end
end
