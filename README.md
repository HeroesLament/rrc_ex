# rrc_ex

Elixir implementation of [Reticulum Relay Chat](https://rrc.kc1awv.net/) (RRC).
Provides both client and hub roles for the RRC v1 protocol, built on top of
[reticulum_ex](https://codeberg.org/heroeslament/reticulum_ex).

## Status

**Early — alpha, scaffold stage.**

| Component                 | Status      |
|---------------------------|-------------|
| `RRC.Frame` codec         | implemented |
| `RRC.Room` normalization  | implemented |
| Behavior contracts        | implemented |
| `RRC.Storage.InMemory`    | implemented |
| `RRC.Storage.Null`        | implemented |
| `RRC.Hub.Moderator` default | implemented |
| `RRC.Transport.RNS`       | stub        |
| `RRC.Client` state machine | stub       |
| `RRC.Hub` lifecycle       | stub        |
| `RRC.Hub.Session` per-link | stub       |
| Fanout routing            | stub        |

The Frame codec round-trips the worked examples from spec chapter 3.
Client and Hub modules compile but do not yet connect to anything real.

## Why this library exists

The Reticulum ecosystem has Python implementations of RRC (rrcd as hub,
rrc-tui / rrc-gui / rrc-web as clients). This is the first Elixir
implementation, intended to work on:

- **Desktop** — terminal clients (hailer), GUI clients
- **Mobile** — Elixir backends shipped with mobile apps
- **Server** — headless hubs, bots, gateways

Because the same library must work across all three contexts, anything
platform-specific is expressed as a **behavior** that the using application
implements for its environment.

## Architecture: behaviors are the platform seams

rrc_ex is split into three categories of code:

**Pure protocol logic.** No platform assumptions. Same on every target.

- `RRC.Frame` — CBOR envelope codec
- `RRC.Room` — room name normalization
- The state machines inside `RRC.Client` and `RRC.Hub`

**Behaviors.** Platform-supplied contracts.

- `RRC.Storage` — file/database access
- `RRC.Handler` — application event sink (where incoming messages go)
- `RRC.Transport` — Reticulum Link access (so tests can use a fake)
- `RRC.Hub.Moderator` — operator policy for hub-side decisions

**Reference implementations.** Useful out-of-the-box, replaceable.

- `RRC.Storage.InMemory` — ETS-backed, works on every BEAM
- `RRC.Storage.Null` — no-op for stateless contexts
- `RRC.Transport.RNS` — production default, uses reticulum_ex directly

A mobile app would write its own `Storage` adapter using whatever
iOS or Android persistence makes sense, but the rest of the library
is unchanged.

## Not an OTP application

rrc_ex is a **library**, not an application. It does not auto-start
anything. The consuming application supervises whatever combination
of `RRC.Client` and `RRC.Hub` processes it needs.

A bot starts only a client. A dedicated hub server starts only a hub.
An app like hailer may start both — connecting to a remote hub while
also hosting a local one — in the same BEAM, with no conflict.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:rrc_ex, git: "https://github.com/HeroesLament/rrc_ex.git"}
  ]
end
```

## Usage

### Client

```elixir
defmodule MyApp.RRCHandler do
  use RRC.Handler

  @impl true
  def handle_message(%RRC.Frame{type: :msg, room: room, body: text} = frame, _ctx) do
    IO.puts("[#{room}] #{frame.nickname || "?"}: #{text}")
    :ok
  end

  @impl true
  def handle_session_active(hub_info, %{client: client}) do
    IO.puts("Connected to #{hub_info[:name] || "unnamed hub"}")
    RRC.Client.join(client, "general")
    :ok
  end
end

{:ok, client} = RRC.Client.start_link(
  hub: Base.decode16!("28c7c1a68c735693aa8e6b8193ed44b2", case: :lower),
  identity: my_identity,
  handler: MyApp.RRCHandler,
  nickname: "anon",
  client_name: "my-app",
  client_version: "0.1.0",
  transport: {RRC.Transport.RNS, []},
  storage: {RRC.Storage.InMemory, []}
)

RRC.Client.msg(client, "general", "hello, world")
```

### Hub

```elixir
defmodule MyHub.Moderator do
  use RRC.Hub.Moderator

  @impl true
  def authorize_message(_session, %RRC.Frame{body: body}) when byte_size(body) > 300 do
    {:deny, "too long"}
  end
  def authorize_message(_session, _frame), do: :allow
end

{:ok, hub} = RRC.Hub.start_link(
  identity: hub_identity,
  hub_name: "my-hub",
  hub_version: "0.1.0",
  limits: %{
    max_nick_bytes: 32,
    max_room_name_bytes: 64,
    max_msg_body_bytes: 350,
    rate_limit_msgs_per_minute: 60
  },
  moderator: MyHub.Moderator,
  transport: {RRC.Transport.RNS, []},
  storage: {RRC.Storage.InMemory, []}
)
```

### Both at once

Nothing prevents a single BEAM from running both. Use the `:name` option
to keep them addressable separately:

```elixir
children = [
  {RRC.Client, [..., name: MyApp.Client]},
  {RRC.Hub,    [..., name: MyApp.Hub]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

## Development

```sh
mix deps.get
mix compile
mix test
```

Tests exercise the Frame codec against the spec's worked examples and
verify behavior contracts. Integration tests against a real hub require
manual setup.

## License

MIT.
