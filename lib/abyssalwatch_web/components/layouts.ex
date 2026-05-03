defmodule AbyssalwatchWeb.Layouts do
  @moduledoc """
  App layout. Renders the topbar (brand + nav + user menu), the main content
  region, and the flash group. Single dark theme by design — see DESIGN.md.
  """
  use AbyssalwatchWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the application shell.

  ## Examples

      <Layouts.app flash={@flash} current_user={@current_user} active={:search}>
        ...
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_user, :any, default: nil, doc: "the current user"

  attr :active, :atom,
    default: nil,
    doc: "the active nav key, one of :search, :optimize, :watch"

  attr :inner_content, :any, default: nil, doc: "the inner content (when used as layout)"
  slot :inner_block, doc: "inner block slot (when used as component)"

  def app(assigns) do
    ~H"""
    <header class="topbar">
      <a href="/" class="topbar-brand" aria-label="AbyssalWatch home">
        <span class="topbar-brand-mark" aria-hidden="true" />
        <span class="hidden sm:inline">AbyssalWatch</span>
      </a>

      <nav class="topbar-nav" aria-label="Primary">
        <.nav_link href="/search" active={@active == :search}>Search</.nav_link>
        <.nav_link href="/optimize" active={@active == :optimize}>Optimize</.nav_link>
        <.nav_link href="/watch" active={@active == :watch}>Watch</.nav_link>
      </nav>

      <div class="flex items-center gap-2">
        <%= if @current_user do %>
          <.user_menu user={@current_user} />
        <% else %>
          <.link href="/sign-in" class="btn btn-primary btn-sm">Sign in</.link>
        <% end %>
      </div>
    </header>

    <main class="app-main">
      <%= if @inner_content do %>
        {@inner_content}
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <a href={@href} class="topbar-nav-link" aria-current={@active && "page"}>
      {render_slot(@inner_block)}
    </a>
    """
  end

  attr :user, :any, required: true

  defp user_menu(assigns) do
    ~H"""
    <details class="relative">
      <summary class="btn btn-ghost btn-sm list-none cursor-pointer">
        <img
          src={"https://images.evetech.net/characters/#{@user.character_id}/portrait?size=64"}
          alt=""
          class="size-5 rounded-full"
        />
        <span class="hidden sm:inline">{@user.character_name}</span>
        <.icon name="hero-chevron-down" class="size-3 text-ink-3" />
      </summary>
      <div class="absolute right-0 mt-2 w-56 panel py-1 shadow-[var(--shadow-popover)] z-40">
        <a
          href="/watch"
          class="flex items-center gap-2 px-3 py-2 text-sm text-ink-2 hover:bg-surface-2 hover:text-ink-1"
        >
          <.icon name="hero-bell-alert" class="size-4 text-ink-3" /> Watch
        </a>
        <div class="my-1 border-t border-rule-1"></div>
        <.link
          href="/logout"
          method="delete"
          class="flex items-center gap-2 px-3 py-2 text-sm text-status-error hover:bg-surface-2"
        >
          <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Sign out
        </.link>
      </div>
    </details>
    """
  end

  @doc """
  Renders the flash group plus the disconnected/server-error reconnect banners.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="toast-stack" aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection lost")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Server error")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
