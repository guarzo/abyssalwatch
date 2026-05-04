# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AbyssalWatch is an EVE Online Abyssal Module Analysis Platform built with Elixir, Phoenix 1.8, Ash Framework 3.x, and LiveView. It enables players to search, analyze, score, and optimize mutaplasmid-modified modules for ship fittings.

## Commands

```bash
# Development
mix setup              # Install deps, setup DB, build assets
mix phx.server         # Start Phoenix server (http://localhost:4000)
mix precommit          # Run before committing: compile --warnings-as-errors, unlock unused deps, format, test

# Testing
# Use `mix precommit` to run the full gate (it sets MIX_ENV=test internally).
# For ad-hoc test runs, set MIX_ENV explicitly — Mix's automatic env-switch
# for `mix test` does not work in this project (alias interaction).
MIX_ENV=test mix test                            # Run all tests
MIX_ENV=test mix test path/to/test.exs           # Run single test file
MIX_ENV=test mix test path/to/test.exs:42        # Run test at specific line
MIX_ENV=test mix test --failed                   # Re-run failed tests

# Database
mix ecto.migrate       # Run migrations
mix ecto.reset         # Drop, create, migrate, seed

# Ash-specific
mix ash.codegen        # Generate Ash resource code
```

## Architecture

### Ash Domains (lib/abyssalwatch/)

The app uses Ash Framework with four domains defined in `config/config.exs`:

- **Accounts** - User auth via EVE SSO, tokens, notification settings
- **Market** - Abyssal modules, types, Mutamarket API client, TOPSIS scoring
- **Watchlists** - User watchlists, matching logic, Discord notifications
- **Fittings** - Ship fittings, ESI integration, format parsers (EFT, DNA, XML)

### Web Layer (lib/abyssalwatch_web/)

- **Router** - Public routes at `/`, auth-required ESI routes at `/esi/*`
- **LiveViews** - SearchLive, OptimizationLive, DashboardLive, WatchlistLive, FittingLive, ESIFittingsLive
- **Authentication** - EVE SSO OAuth2 via `Plugs.Auth` and `LiveAuth` on_mount hooks

### Key Background Processes

- `Market.Mutamarket.Cache` - ETS-based API response caching
- `Market.Mutamarket.RateLimiter` - Token bucket rate limiting
- `Watchlists.Monitor` - GenServer for background watchlist checks
- `Watchlists.Discord.Client` - Webhook notifications

## External APIs

- **Mutamarket API** - Abyssal module market data (cached, rate-limited)
- **EVE ESI** - Character fittings, OAuth2 via SSO
- **Discord Webhooks** - Watchlist match notifications

---

# Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

## Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `AbyssalwatchWeb.Layouts` module is aliased in the `abyssalwatch_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">`), no default classes are inherited, so your custom classes must fully style the input

## JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive interfaces
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/abyssalwatch_web";

- **Always use and maintain this import syntax** in `app.css`
- **Never** use `@apply` when writing raw CSS
- **Always** manually write your own tailwind-based components instead of using daisyUI
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import vendor deps into app.js and app.css
  - **Never write inline `<script>` tags within templates** — use colocated hooks (see LiveView section)

## UI/UX & design guidelines

- Produce world-class UI: usability, aesthetics, modern design principles
- Subtle micro-interactions (button hover, smooth transitions)
- Clean typography, spacing, and layout balance
- Delightful details: hover effects, loading states, smooth page transitions

---

<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc you *must* bind the result of the expression to a variable if you want to use it. You CANNOT rebind the result inside the expression:

      # INVALID: rebinding inside the `if` — result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: rebind the result of the `if`
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file — can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs. Access fields directly (`my_struct.field`) or use `Ecto.Changeset.get_field/2`
- Elixir's standard library has everything for date/time. Use `Time`, `Date`, `DateTime`, `Calendar`. **Never** install additional date deps unless asked (use `date_time_parser` only for parsing)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end with `?`. `is_thing` is reserved for guards
- OTP primitives like `DynamicSupervisor` and `Registry` require names in the child spec: `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. Usually pass `timeout: :infinity`

## Mix guidelines

- Read docs/options before using tasks (`mix help task_name`)
- To debug test failures, run a specific file with `mix test test/my_test.exs` or all previously failed with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests — guarantees cleanup
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping for a process to finish, use `Process.monitor/1`:

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - Instead of sleeping to synchronize before the next call, use `_ = :sys.get_state/1`
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Router `scope` blocks include an optional alias prefixed for all routes within the scope. Be mindful when creating routes within a scope to avoid duplicate module prefixes.
- You **never** need your own `alias` for route definitions — `scope` provides it:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser
        live "/users", UserLive, :index
      end

  `UserLive` resolves to `AppWeb.Admin.UserLive`.

- `Phoenix.View` no longer needed or included with Phoenix — don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates (e.g. `message.user.email`)
- Remember `import Ecto.Query` and supporting modules in `seeds.exs`
- `Ecto.Schema` fields always use `:string` (even for `:text` columns): `field :name, :string`
- `Ecto.Changeset.validate_number/2` **does not support `:allow_nil`** — Ecto validations only run on present, non-nil changes
- Use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields set programmatically (e.g. `user_id`) must NOT be in `cast` calls — set them explicitly when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` for migrations
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or `.html.heex` files. **Never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` to build forms. Never use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for`
- When building forms **always** use `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access via `@form[:field]`
- **Always** add unique DOM IDs to key elements (forms, buttons) for use in tests: `<.form for={@form} id="product-form">`
- For app-wide template imports, import/alias into `abyssalwatch_web.ex`'s `html_helpers` block

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. Use `cond` or `case`:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx requires `phx-no-curly-interpolation` annotation on parent tags if you want to display literal `{` or `}`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

- HEEx class attrs support **list** syntax — always use `[...]` for multiple/conditional classes:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
      ]}>Text</a>

  Wrap inline `if` inside `{...}` with parens. Never omit the `[ ]` — that raises a syntax error.

- **Never** use `<% Enum.each %>` or non-for comprehensions for template content. Always use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`
- HEEx interpolation: use `{...}` for tag attributes and tag bodies; use `<%= ... %>` only for block constructs (if/cond/case/for) inside tag bodies:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use deprecated `live_redirect` / `live_patch`. Use `<.link navigate={href}>` and `<.link patch={href}>` in templates, and `push_navigate` / `push_patch` in LiveViews
- **Avoid LiveComponents** unless you have a strong, specific need
- LiveViews are named with a `Live` suffix (e.g. `AbyssalwatchWeb.SearchLive`). The `:browser` scope is already aliased with `AbyssalwatchWeb`, so `live "/search", SearchLive` is enough

### LiveView streams

- **Always** use LiveView streams for collections to avoid memory ballooning:
  - append: `stream(socket, :messages, [new_msg])`
  - reset: `stream(socket, :messages, [new_msg], reset: true)`
  - prepend: `stream(socket, :messages, [new_msg], at: -1)`
  - delete: `stream_delete(socket, :messages, msg)`

- Streams require `phx-update="stream"` on the parent with a DOM `id`, and consuming `@streams.stream_name`:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- Streams are **not enumerable** — no `Enum.filter/2`. To filter, refetch and re-stream with `reset: true`
- Streams **don't support counting or empty states**. Track counts in a separate assign. For empty states use Tailwind:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>{task.name}</div>
      </div>

- When updating an assign that affects streamed item content, you MUST re-stream the item alongside the assign update (use `stream_insert/3`)
- **Never** use deprecated `phx-update="append"` / `phx-update="prepend"`

### LiveView JavaScript interop

- When `phx-hook="MyHook"` manages its own DOM, also set `phx-update="ignore"`
- Always provide a unique DOM id alongside `phx-hook` (compiler error otherwise)

#### Inline colocated JS hooks

**Never** write raw `<script>` tags in HEEx. Use colocated hooks:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if (match) this.el.value = `${match[1]}-${match[2]}-${match[3]}`
          })
        }
      }
    </script>

- Colocated hooks integrate into the app.js bundle automatically
- Names **must** start with `.` (e.g. `.PhoneNumber`)

#### External `phx-hook`

External hooks live in `assets/js/` and are passed to `LiveSocket`:

    const MyHook = { mounted() { ... } }
    let liveSocket = new LiveSocket("/live", Socket, { hooks: { MyHook } });

#### Pushing events between client/server

Use `push_event/3`. **Always** rebind/return the socket:

    socket = push_event(socket, "my_event", %{...})

Client side:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Client → server with reply:

    this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply:", reply));

Server:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- Use `Phoenix.LiveViewTest` and `LazyHTML` for assertions
- Form tests: `render_submit/2`, `render_change/2`
- **Always reference key element IDs** in tests via `element/2`, `has_element?/2`
- **Never** test against raw HTML — always `element/2` / `has_element?/2`: `assert has_element?(view, "#my-form")`
- Favor presence of key elements over text content; test outcomes, not implementation
- For debugging selectors, use `LazyHTML.from_fragment` + `LazyHTML.filter`

### Form handling

#### From params

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

To nest:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### From changesets

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Then in template:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form a unique DOM id.

#### Avoiding form errors

**Always** use a `to_form/2`-assigned form and `<.input>`. **Never** access changesets in templates:

    <%!-- VALID --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

    <%!-- INVALID — will error --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template
- **Never** use `<.form let={f} ...>` — always `<.form for={@form} ...>` and drive references via `@form[:field]`
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
