# Audit Log IP Geography Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the country (flag + name) of the IP address next to each entry on the `/dashboard/audit-logs` page, resolved at render time from the already-stored `remote_ip`.

**Architecture:** Add a swappable `Hexpm.Geo` behaviour (mirroring the existing `Hexpm.Pwned` pattern) with three implementations — `Local` (no-op, dev/test default), `Geolix` (prod, MaxMind GeoLite2-Country lookup), and a Mox `Mock` (targeted tests). The `AuditLogCard` component resolves `log.remote_ip` to a country at render time and appends a flag + country name under each entry's timestamp. No new schema column or migration: `remote_ip` already exists on every `audit_logs` row.

**Tech Stack:** Elixir / Phoenix, `geolix` + `geolix_adapter_mmdb2` (MaxMind MMDB reader), Mox for test doubles, ExUnit + `Phoenix.LiveViewTest` for component tests.

---

## Project Notes (read before starting)

- **Behaviour/impl swap pattern** the project already uses (copy it exactly): `lib/hexpm/pwned/pwned.ex` defines `@callback` + `defp impl(), do: Application.get_env(:hexpm, :pwned_impl)` + a thin public dispatch fn. Implementations are `Hexpm.Pwned.Local` (dev), `Hexpm.Pwned.HaveIBeenPwned` (prod), `Hexpm.Pwned.Mock`. The impl is selected per env in `config/config.exs` (dev/default), `config/prod.exs` (prod), `config/test.exs` (test).
- **Mock definitions** live in `test/support/mocks.ex` via `Mox.defmock(..., for: <behaviour>)`.
- **Render-time decision:** geolocation is resolved during rendering, NOT stored. This means dev/test default to `Hexpm.Geo.Local` (returns `nil`), so the location line simply does not appear and **all existing audit-log tests stay green untouched**.
- **MaxMind licensing note (per request):** GeoLite2 is free but requires a MaxMind account, acceptance of their EULA, and **visible attribution**. Task 7 adds an attribution line to the page. The `.mmdb` file is provided to prod via the `HEXPM_GEOLITE2_COUNTRY_PATH` env var (Task 4); sourcing/refreshing that file is an ops concern out of scope for this plan, but the env var + config wiring is included so prod is ready for it.
- **Private/loopback/old IPs:** pre-2022 rows have `remote_ip = nil` and internal IPs won't resolve. Both paths return `nil` and the location line is omitted. Covered by tests.

## File Structure

- Create `lib/hexpm/geo/geo.ex` — `Hexpm.Geo`: behaviour (`@callback lookup_country/1`), dispatcher, and pure `flag_emoji/1` helper.
- Create `lib/hexpm/geo/local.ex` — `Hexpm.Geo.Local`: no-op impl returning `nil` (dev/test default).
- Create `lib/hexpm/geo/geolix.ex` — `Hexpm.Geo.Geolix`: prod impl calling `Geolix.lookup/2` + pure `parse_result/1`.
- Modify `mix.exs` — add `:geolix` and `:geolix_adapter_mmdb2` deps.
- Modify `config/config.exs`, `config/test.exs`, `config/prod.exs` — set `geo_impl` per env.
- Modify `config/runtime.exs` — configure the GeoLite2 database for prod via env var.
- Modify `test/support/mocks.ex` — add `Hexpm.Geo.Mock`.
- Modify `lib/hexpm_web/templates/dashboard/audit_log/components/audit_log_card.ex` — resolve + render location in `timeline_item/1`.
- Modify `lib/hexpm_web/templates/dashboard/audit_log/index.html.heex` — MaxMind attribution line.
- Create `test/hexpm/geo/geo_test.exs` — dispatcher + `flag_emoji/1` tests.
- Create `test/hexpm/geo/geolix_test.exs` — `parse_result/1` tests.
- Create `test/hexpm_web/templates/dashboard/audit_log/components/audit_log_card_test.exs` — component render tests (location present / absent).
- Modify `test/hexpm_web/controllers/dashboard/audit_log_controller_test.exs` — attribution assertion.

---

## Task 1: Add geolix dependencies

**Files:**
- Modify: `mix.exs` (the `defp deps()` list)

- [ ] **Step 1: Add the deps**

In `mix.exs`, inside the `defp deps()` list, add these two entries (alphabetical placement near the other `g*`/`goth` entries is fine):

```elixir
{:geolix, "~> 2.0"},
{:geolix_adapter_mmdb2, "~> 0.6"},
```

- [ ] **Step 2: Fetch deps**

Run: `mix deps.get`
Expected: resolves and downloads `geolix` and `geolix_adapter_mmdb2` (plus transitive `mmdb2_decoder`) with no version conflicts.

- [ ] **Step 3: Compile**

Run: `mix compile`
Expected: compiles cleanly (warnings about the new unused modules are fine — they're added in later tasks).

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "feat: add geolix dependency for audit log geolocation"
```

---

## Task 2: Create the `Hexpm.Geo` behaviour + dispatcher + flag helper

**Files:**
- Create: `lib/hexpm/geo/geo.ex`
- Test: `test/hexpm/geo/geo_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hexpm/geo/geo_test.exs`:

```elixir
defmodule Hexpm.GeoTest do
  use ExUnit.Case, async: true

  describe "flag_emoji/1" do
    test "converts a two-letter ISO code to a flag emoji" do
      assert Hexpm.Geo.flag_emoji("US") == <<0x1F1FA::utf8, 0x1F1F8::utf8>>
      assert Hexpm.Geo.flag_emoji("DE") == <<0x1F1E9::utf8, 0x1F1EA::utf8>>
    end

    test "returns empty string for anything that is not a 2-letter A-Z code" do
      assert Hexpm.Geo.flag_emoji("USA") == ""
      assert Hexpm.Geo.flag_emoji("u") == ""
      assert Hexpm.Geo.flag_emoji("us") == ""
      assert Hexpm.Geo.flag_emoji("") == ""
    end
  end

  describe "lookup_country/1" do
    test "returns nil for a nil IP without calling the implementation" do
      assert Hexpm.Geo.lookup_country(nil) == nil
    end

    test "delegates to the configured implementation (Local default returns nil)" do
      # config/test.exs sets geo_impl: Hexpm.Geo.Local
      assert Hexpm.Geo.lookup_country("8.8.8.8") == nil
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hexpm/geo/geo_test.exs`
Expected: FAIL — `Hexpm.Geo` is undefined (module not yet created), and `geo_impl` not yet configured.

- [ ] **Step 3: Create the module**

Create `lib/hexpm/geo/geo.ex`:

```elixir
defmodule Hexpm.Geo do
  @moduledoc """
  Resolves IP address strings to a country, for display in audit logs.

  The active implementation is selected via the `:geo_impl` application
  environment. See `Hexpm.Geo.Local` (dev/test) and `Hexpm.Geo.Geolix` (prod).
  """

  @typedoc "A resolved country, or nil when the IP could not be located."
  @type country :: %{iso_code: String.t(), name: String.t()} | nil

  @callback lookup_country(ip :: String.t()) :: country()

  defp impl(), do: Application.get_env(:hexpm, :geo_impl)

  @doc """
  Resolves an IP string to a `%{iso_code, name}` map, or nil when it cannot be
  located (including unresolvable/private IPs and a nil input).
  """
  @spec lookup_country(String.t() | nil) :: country()
  def lookup_country(nil), do: nil
  def lookup_country(ip) when is_binary(ip), do: impl().lookup_country(ip)

  @doc """
  Converts a two-letter ISO 3166-1 alpha-2 country code into its flag emoji
  using Unicode regional indicator symbols. Returns "" for any other input.
  """
  @spec flag_emoji(String.t()) :: String.t()
  def flag_emoji(<<a, b>>) when a in ?A..?Z and b in ?A..?Z do
    <<127_397 + a::utf8, 127_397 + b::utf8>>
  end

  def flag_emoji(_), do: ""
end
```

- [ ] **Step 4: Configure the test/default implementation**

This test depends on `geo_impl` being set. Add it now in two files.

In `config/config.exs`, in the top `config :hexpm,` keyword list, add `geo_impl: Hexpm.Geo.Local,` right after the `pwned_impl: Hexpm.Pwned.Local,` line:

```elixir
  billing_impl: Hexpm.Billing.Local,
  pwned_impl: Hexpm.Pwned.Local,
  geo_impl: Hexpm.Geo.Local,
  sudo_timeout: Duration.new!(hour: 1)
```

In `config/test.exs`, next to the existing `pwned_impl: Hexpm.Pwned.Mock,` / `billing_impl:` lines, add:

```elixir
  geo_impl: Hexpm.Geo.Local,
```

(Test default is `Local`, not `Mock`, so existing audit-log tests are unaffected — the location line just doesn't render. The component test in Task 6 overrides to `Mock` locally.)

The `Hexpm.Geo.Local` module is created in Task 3; this test will stay red until then. That's expected — proceed.

- [ ] **Step 5: Commit**

```bash
git add lib/hexpm/geo/geo.ex test/hexpm/geo/geo_test.exs config/config.exs config/test.exs
git commit -m "feat: add Hexpm.Geo behaviour, dispatcher and flag_emoji helper"
```

---

## Task 3: Create the `Hexpm.Geo.Local` no-op implementation

**Files:**
- Create: `lib/hexpm/geo/local.ex`

- [ ] **Step 1: Create the module**

Create `lib/hexpm/geo/local.ex`:

```elixir
defmodule Hexpm.Geo.Local do
  @moduledoc "No-op geo implementation used in dev and test; never resolves a country."
  @behaviour Hexpm.Geo

  @impl Hexpm.Geo
  def lookup_country(_ip), do: nil
end
```

- [ ] **Step 2: Run the Task 2 test to verify it now passes**

Run: `mix test test/hexpm/geo/geo_test.exs`
Expected: PASS (all `flag_emoji/1` and `lookup_country/1` cases green now that `Hexpm.Geo.Local` exists and `geo_impl` is configured).

- [ ] **Step 3: Commit**

```bash
git add lib/hexpm/geo/local.ex
git commit -m "feat: add Hexpm.Geo.Local no-op geolocation implementation"
```

---

## Task 4: Create the `Hexpm.Geo.Geolix` production implementation

**Files:**
- Create: `lib/hexpm/geo/geolix.ex`
- Test: `test/hexpm/geo/geolix_test.exs`
- Modify: `config/prod.exs`, `config/runtime.exs`

- [ ] **Step 1: Write the failing test**

The live `Geolix.lookup/2` call needs a binary `.mmdb` database, which we do not exercise in unit tests. Instead we test the pure `parse_result/1` transformation against maps shaped like the Geolix MMDB2 adapter output.

Create `test/hexpm/geo/geolix_test.exs`:

```elixir
defmodule Hexpm.Geo.GeolixTest do
  use ExUnit.Case, async: true

  alias Hexpm.Geo.Geolix

  describe "parse_result/1" do
    test "extracts iso_code and resolved name" do
      result = %{country: %{iso_code: "US", name: "United States"}}
      assert Geolix.parse_result(result) == %{iso_code: "US", name: "United States"}
    end

    test "falls back to the english name when :name is absent" do
      result = %{country: %{iso_code: "US", names: %{"en" => "United States"}}}
      assert Geolix.parse_result(result) == %{iso_code: "US", name: "United States"}
    end

    test "falls back to the iso code when no name is available" do
      result = %{country: %{iso_code: "DE"}}
      assert Geolix.parse_result(result) == %{iso_code: "DE", name: "DE"}
    end

    test "returns nil when the country has no iso_code" do
      assert Geolix.parse_result(%{country: %{}}) == nil
    end

    test "returns nil for a missing/empty/nil lookup result" do
      assert Geolix.parse_result(%{}) == nil
      assert Geolix.parse_result(nil) == nil
      assert Geolix.parse_result({:error, :not_found}) == nil
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hexpm/geo/geolix_test.exs`
Expected: FAIL — `Hexpm.Geo.Geolix` is undefined.

- [ ] **Step 3: Create the module**

Create `lib/hexpm/geo/geolix.ex`:

```elixir
defmodule Hexpm.Geo.Geolix do
  @moduledoc """
  Resolves IPs to a country using a MaxMind GeoLite2-Country database via the
  `:geolix` library. The database is configured under `config :geolix` with the
  id `:country` (see `config/runtime.exs`).
  """
  @behaviour Hexpm.Geo

  @impl Hexpm.Geo
  def lookup_country(ip) when is_binary(ip) do
    ip
    |> Geolix.lookup(where: :country)
    |> parse_result()
  end

  @doc false
  def parse_result(%{country: country}) when is_map(country) do
    case Map.get(country, :iso_code) do
      iso when is_binary(iso) -> %{iso_code: iso, name: country_name(country, iso)}
      _ -> nil
    end
  end

  def parse_result(_), do: nil

  defp country_name(country, iso) do
    Map.get(country, :name) ||
      get_in(Map.get(country, :names) || %{}, ["en"]) ||
      iso
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hexpm/geo/geolix_test.exs`
Expected: PASS (all `parse_result/1` cases green).

- [ ] **Step 5: Wire prod to use the Geolix implementation**

In `config/prod.exs`, in the `config :hexpm,` keyword list (next to the existing `billing_impl: Hexpm.Billing.Hexpm,` / `pwned_impl: Hexpm.Pwned.HaveIBeenPwned,` lines), add:

```elixir
  geo_impl: Hexpm.Geo.Geolix,
```

- [ ] **Step 6: Configure the GeoLite2 database for prod**

In `config/runtime.exs`, inside the `if config_env() == :prod do` block (alongside the other prod-only config), add:

```elixir
  config :geolix,
    databases: [
      %{
        id: :country,
        adapter: Geolix.Adapter.MMDB2,
        source: System.fetch_env!("HEXPM_GEOLITE2_COUNTRY_PATH")
      }
    ]
```

(Only prod loads a database file; dev/test use `Hexpm.Geo.Local`/`Mock` and never call `Geolix.lookup`, so `:geolix` boots with no databases there — which is valid.)

- [ ] **Step 7: Compile to verify config is well-formed**

Run: `MIX_ENV=prod mix compile`
Expected: compiles cleanly. (Runtime config is not evaluated at compile time, so no env var is required for this step.)

- [ ] **Step 8: Commit**

```bash
git add lib/hexpm/geo/geolix.ex test/hexpm/geo/geolix_test.exs config/prod.exs config/runtime.exs
git commit -m "feat: add Hexpm.Geo.Geolix GeoLite2-Country implementation"
```

---

## Task 5: Add the `Hexpm.Geo.Mock`

**Files:**
- Modify: `test/support/mocks.ex`

- [ ] **Step 1: Add the mock**

In `test/support/mocks.ex`, add a line alongside the existing `Mox.defmock` calls:

```elixir
Mox.defmock(Hexpm.Geo.Mock, for: Hexpm.Geo)
```

- [ ] **Step 2: Verify the mock compiles**

Run: `mix test test/hexpm/geo/geo_test.exs`
Expected: PASS (still green; this just confirms `mocks.ex` compiles with the new mock — `Hexpm.Geo` defines the `@callback` the mock needs).

- [ ] **Step 3: Commit**

```bash
git add test/support/mocks.ex
git commit -m "test: add Hexpm.Geo.Mock"
```

---

## Task 6: Render location in the AuditLogCard component

**Files:**
- Modify: `lib/hexpm_web/templates/dashboard/audit_log/components/audit_log_card.ex:70-103` (the `timeline_item/1` function)
- Test: `test/hexpm_web/templates/dashboard/audit_log/components/audit_log_card_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hexpm_web/templates/dashboard/audit_log/components/audit_log_card_test.exs`:

```elixir
defmodule HexpmWeb.Dashboard.AuditLog.Components.AuditLogCardTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Mox

  alias HexpmWeb.Dashboard.AuditLog.Components.AuditLogCard
  alias Hexpm.Accounts.AuditLog

  setup do
    prev = Application.get_env(:hexpm, :geo_impl)
    Application.put_env(:hexpm, :geo_impl, Hexpm.Geo.Mock)
    on_exit(fn -> Application.put_env(:hexpm, :geo_impl, prev) end)
    :ok
  end

  defp login_log(attrs \\ %{}) do
    Map.merge(
      %AuditLog{
        action: "session.create",
        remote_ip: "1.2.3.4",
        params: %{"type" => "browser", "name" => "Firefox on macOS"},
        inserted_at: ~U[2026-05-20 12:00:00Z]
      },
      attrs
    )
  end

  test "renders the country name and flag when the IP resolves" do
    stub(Hexpm.Geo.Mock, :lookup_country, fn "1.2.3.4" ->
      %{iso_code: "US", name: "United States"}
    end)

    html = render_component(&AuditLogCard.audit_log_card/1, audit_logs: [login_log()])

    assert html =~ "United States"
    assert html =~ Hexpm.Geo.flag_emoji("US")
  end

  test "omits the location when the IP does not resolve" do
    stub(Hexpm.Geo.Mock, :lookup_country, fn _ -> nil end)

    html =
      render_component(&AuditLogCard.audit_log_card/1,
        audit_logs: [login_log(%{remote_ip: nil})]
      )

    assert html =~ "Logged in from Firefox on macOS"
    refute html =~ "United States"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hexpm_web/templates/dashboard/audit_log/components/audit_log_card_test.exs`
Expected: FAIL — the "renders the country name and flag" test fails because `timeline_item/1` does not yet resolve or render the location.

- [ ] **Step 3: Update `timeline_item/1` to resolve and render the location**

In `lib/hexpm_web/templates/dashboard/audit_log/components/audit_log_card.ex`, replace the entire `timeline_item/1` function (currently lines 70-103) with:

```elixir
  defp timeline_item(assigns) do
    icon = icon_for_action(assigns.log.action)
    description = humanize_action(assigns.log)
    geo = Hexpm.Geo.lookup_country(assigns.log.remote_ip)
    assigns = assign(assigns, icon: icon, description: description, geo: geo)

    ~H"""
    <div class="flex gap-4 group">
      <%!-- Left column: dot + connector line --%>
      <div class="flex flex-col items-center flex-shrink-0">
        <%!-- Circle dot --%>
        <div class="w-8 h-8 rounded-full border-2 border-grey-200 dark:border-grey-600 bg-white dark:bg-grey-900 flex items-center justify-center z-10 text-grey-400 dark:text-grey-300">
          {icon(:heroicon, @icon, width: 16, height: 16)}
        </div>
        <%!-- Vertical connector line (hidden on last item) --%>
        <%= unless @is_last do %>
          <div class="w-px flex-1 bg-grey-200 dark:bg-grey-700 my-1 min-h-[20px]"></div>
        <% end %>
      </div>

      <%!-- Right column: action text + date --%>
      <div class="pb-6 flex-1 min-w-0">
        <p class="text-base font-medium text-grey-700 dark:text-grey-100 leading-6">
          {@description}
        </p>
        <p
          class="text-xs font-medium text-grey-500 dark:text-grey-300 mt-0.5"
          title={ViewHelpers.pretty_datetime(@log.inserted_at)}
        >
          {ViewHelpers.pretty_date(@log.inserted_at, :short)}
          <%= if @geo do %>
            <span class="ml-2 text-grey-400 dark:text-grey-400">
              {Hexpm.Geo.flag_emoji(@geo.iso_code)} {@geo.name}
            </span>
          <% end %>
        </p>
      </div>
    </div>
    """
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hexpm_web/templates/dashboard/audit_log/components/audit_log_card_test.exs`
Expected: PASS (both tests green).

- [ ] **Step 5: Run the existing audit-log tests to confirm no regression**

Run: `mix test test/hexpm_web/controllers/dashboard/audit_log_controller_test.exs`
Expected: PASS (test default `geo_impl: Hexpm.Geo.Local` returns nil, so the location line is absent and these assertions are unaffected).

- [ ] **Step 6: Commit**

```bash
git add lib/hexpm_web/templates/dashboard/audit_log/components/audit_log_card.ex test/hexpm_web/templates/dashboard/audit_log/components/audit_log_card_test.exs
git commit -m "feat: show IP country and flag on audit log entries"
```

---

## Task 7: Add MaxMind attribution to the audit log page

**Files:**
- Modify: `lib/hexpm_web/templates/dashboard/audit_log/index.html.heex:9-27`
- Test: `test/hexpm_web/controllers/dashboard/audit_log_controller_test.exs`

- [ ] **Step 1: Write the failing test**

In `test/hexpm_web/controllers/dashboard/audit_log_controller_test.exs`, add this test inside the `describe "GET /dashboard/audit-logs"` block (after the existing "shows page successfully after login" test):

```elixir
    test "shows MaxMind attribution for location data" do
      user = insert(:user)

      response =
        build_conn()
        |> test_login(user)
        |> get("/dashboard/audit-logs")
        |> html_response(:ok)

      assert response =~ "MaxMind"
    end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hexpm_web/controllers/dashboard/audit_log_controller_test.exs`
Expected: FAIL on the new test — the page does not yet contain "MaxMind".

- [ ] **Step 3: Add the attribution line**

In `lib/hexpm_web/templates/dashboard/audit_log/index.html.heex`, inside the right-content `<div class="flex-1 min-w-0">`, add an attribution paragraph immediately after the pagination block (after the closing `<% end %>` on line 26, before the closing `</div>` on line 27):

```heex
        <p class="mt-4 text-xs text-grey-400 dark:text-grey-500">
          Location data by
          <a href="https://www.maxmind.com" class="underline hover:text-grey-600 dark:hover:text-grey-300">MaxMind</a>
          GeoLite2.
        </p>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hexpm_web/controllers/dashboard/audit_log_controller_test.exs`
Expected: PASS (the new attribution test and all existing tests green).

- [ ] **Step 5: Commit**

```bash
git add lib/hexpm_web/templates/dashboard/audit_log/index.html.heex test/hexpm_web/controllers/dashboard/audit_log_controller_test.exs
git commit -m "feat: add MaxMind GeoLite2 attribution to audit log page"
```

---

## Final Verification

- [ ] **Run the full geo + audit-log test surface**

Run:
```bash
mix test test/hexpm/geo/ test/hexpm_web/templates/dashboard/audit_log/ test/hexpm_web/controllers/dashboard/audit_log_controller_test.exs
```
Expected: all PASS.

- [ ] **Format check**

Run: `mix format --check-formatted`
Expected: no formatting diffs (run `mix format` first if needed and amend the relevant commit, or add a follow-up format commit).

---

## Out of scope / follow-ups

- **Backfilled `country` column** — explicitly rejected in favor of render-time resolution. Revisit only if you later need to *query/aggregate* audit logs by country.
- **City-level granularity** — Country DB chosen for accuracy and size. Switching to GeoLite2-City would require a different database id/adapter result struct (`%{city: ...}`) and `parse_result/1` changes.
- **Scoping to login events only** — this plan shows the location on every entry that has a resolvable IP (which inherently covers `session.create`/`session.revoke` logins). To restrict it to login/logout rows only, guard in `timeline_item/1` with e.g. `geo = if String.starts_with?(assigns.log.action, "session."), do: Hexpm.Geo.lookup_country(assigns.log.remote_ip), else: nil`.
- **Sourcing/refreshing the `.mmdb` file** — ops concern (MaxMind account + periodic download). The plan wires `HEXPM_GEOLITE2_COUNTRY_PATH` so prod is ready once the file is provided.
