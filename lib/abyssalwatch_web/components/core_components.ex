defmodule AbyssalwatchWeb.CoreComponents do
  @moduledoc """
  Core UI components for AbyssalWatch.

  Built on Tailwind CSS v4 and the design tokens defined in `assets/css/app.css`.
  Reads the design system from `DESIGN.md` (Cool Slate, Restrained):
  OKLCH neutrals, one muted-indigo accent, 1px hairline rules instead of
  shadows, no gradients, no glass.
  """
  use Phoenix.Component
  use Gettext, backend: AbyssalwatchWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash notice. The `flash` map drives the visible message; the
  optional inner block overrides it (used for the disconnected/server-error
  banners).
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role="alert"
      class={[
        "toast-item",
        @kind == :info && "toast-info",
        @kind == :error && "toast-error"
      ]}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      {@rest}
    >
      <.icon
        name={if @kind == :error, do: "hero-exclamation-circle", else: "hero-information-circle"}
        class="size-5 shrink-0 text-ink-3"
      />
      <div class="flex-1 min-w-0">
        <p :if={@title} class="font-semibold text-ink-1 leading-tight mb-0.5">{@title}</p>
        <p class="text-ink-2 break-words">{msg}</p>
      </div>
      <button
        type="button"
        class="text-ink-3 hover:text-ink-1 transition-colors"
        aria-label={gettext("close")}
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    """
  end

  @doc """
  Renders a button or button-shaped link.

  ## Examples

      <.button>Save</.button>
      <.button variant="primary" phx-click="confirm">Confirm</.button>
      <.button variant="ghost" navigate={~p"/search"}>Search</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any, default: nil
  attr :variant, :string, default: "default", values: ~w(default primary ghost danger)
  attr :size, :string, default: "md", values: ~w(sm md lg)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    classes = [
      "btn",
      assigns.size == "sm" && "btn-sm",
      assigns.size == "lg" && "btn-lg",
      assigns.variant == "primary" && "btn-primary",
      assigns.variant == "ghost" && "btn-ghost",
      assigns.variant == "danger" && "btn-danger",
      assigns.class
    ]

    assigns = assign(assigns, :class, classes)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages. Compatible with
  `Phoenix.HTML.FormField` via `<.input field={@form[:email]} />`.
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="field">
      <label class="flex items-center gap-2 text-ink-2 text-sm cursor-pointer">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class || "checkbox"}
          {@rest}
        />
        <span :if={@label}>{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="field">
      <span :if={@label} class="field-label">{@label}</span>
      <select
        id={@id}
        name={@name}
        class={[@class || "select", @errors != [] && (@error_class || "select-error")]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="field">
      <span :if={@label} class="field-label">{@label}</span>
      <textarea
        id={@id}
        name={@name}
        class={[@class || "textarea", @errors != [] && (@error_class || "textarea-error")]}
        {@rest}
      >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="field">
      <span :if={@label} class="field-label">{@label}</span>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[@class || "input", @errors != [] && (@error_class || "input-error")]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp error(assigns) do
    ~H"""
    <p class="field-error">
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
      <span>{render_slot(@inner_block)}</span>
    </p>
    """
  end

  @doc """
  Renders a page or section header with optional subtitle and action slot.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[
      "flex items-end justify-between gap-6 pb-5 mb-6 border-b border-rule-1",
      @class
    ]}>
      <div class="min-w-0">
        <h1 class="text-[22px] leading-[30px] font-semibold text-ink-1 tracking-tight">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-[13px] text-ink-3">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex-none flex items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  Renders a dense data table. Hairline rules between rows, sticky surface-2
  header, hover surface-2, selected row gets an inset accent rail.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil
  attr :row_click, :any, default: nil

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :class, :any
    attr :align, :string
  end

  slot :action

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="panel overflow-hidden">
      <table class="dense">
        <thead>
          <tr>
            <th
              :for={col <- @col}
              class={[
                col[:align] == "right" && "text-right",
                col[:align] == "center" && "text-center"
              ]}
            >
              {col[:label]}
            </th>
            <th :if={@action != []} class="text-right">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class={@row_click && "cursor-pointer"}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[
                col[:class],
                col[:align] == "right" && "text-right",
                col[:align] == "center" && "text-center"
              ]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="text-right">
              <div class="flex justify-end gap-3">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a definition list of label/value pairs.
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <dl class="divide-y divide-rule-1 border-y border-rule-1">
      <div
        :for={item <- @item}
        class="grid grid-cols-[160px_1fr] gap-4 px-4 py-3 hover:bg-surface-2"
      >
        <dt class="text-[12px] uppercase tracking-wider text-ink-3 font-medium">
          {item.title}
        </dt>
        <dd class="text-ink-1 text-sm tnum">{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  @doc """
  Renders a status pill. Always shows shape glyph + label, never color alone.

  ## Examples

      <.status state={:ready}>Ready</.status>
      <.status state={:queued}>Queued · 4</.status>
  """
  attr :state, :atom,
    required: true,
    values: [:ready, :training, :queued, :idle, :error]

  attr :class, :any, default: nil
  slot :inner_block, required: true

  def status(assigns) do
    glyph =
      case assigns.state do
        :ready -> "●"
        :training -> "◐"
        :queued -> "▸"
        :idle -> "○"
        :error -> "!"
      end

    assigns = assign(assigns, :glyph, glyph)

    ~H"""
    <span class={["pill", "pill-#{@state}", @class]}>
      <span class="pill-glyph" aria-hidden="true">{@glyph}</span>
      <span>{render_slot(@inner_block)}</span>
    </span>
    """
  end

  @doc """
  Renders a Heroicon as a CSS-mask-driven span. The icon name follows the
  `hero-{name}` convention; size and color are set with utility classes.
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS commands ────────────────────────────────────────────────────────

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 180,
      transition:
        {"transition-all ease-out duration-180", "opacity-0 translate-y-1",
         "opacity-100 translate-y-0"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 120,
      transition:
        {"transition-all ease-out duration-120", "opacity-100 translate-y-0",
         "opacity-0 translate-y-1"}
    )
  end

  ## Gettext helpers ────────────────────────────────────────────────────

  @doc "Translates an error message using gettext."
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(AbyssalwatchWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AbyssalwatchWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc "Translates the errors for a field from a keyword list of errors."
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
