defmodule RRC.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/HeroesLament/rrc_ex"

  def project do
    [
      app: :rrc_ex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  # IMPORTANT: this is a library, not an OTP application.
  #
  # rrc_ex provides modules for building RRC clients AND/OR hubs, but it
  # does not auto-start anything. The consuming application supervises
  # whatever combination of `RRC.Client` and `RRC.Hub` processes it needs.
  #
  # The `mod:` callback is intentionally omitted. Only `extra_applications`
  # is set so Logger and the RNS dep are started when an app pulls us in.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      # Reticulum substrate — provides RNS.Link, RNS.Identity, RNS.Destination.
      # Pinned to the same branch hailer currently uses.
      {:rns,
       git: "https://codeberg.org/heroeslament/reticulum_ex.git",
       branch: "feat/announce-forwarding"},

      # CBOR encoder/decoder for RRC envelope serialization.
      # The `cbor` package is mature and handles the canonical encoding
      # rules from RRC spec chapter 3 correctly (integer keys, byte
      # strings, text strings, maps).
      {:cbor, "~> 1.0"},
      # Required by rustler_precompiled :force_build for bz2_ex (via rns).
      {:rustler, ">= 0.0.0", optional: true},
      # TODO: remove this override once bz2_ex 0.1.2 ships to Hex.
      #
      # bz2_ex 0.1.1 on Hex shipped with an empty checksum file, so the
      # precompiled NIF download fails verification. We pin to a local
      # working copy that has the populated checksum file. This means
      # rrc_ex currently requires bz2_ex to be checked out at ../bz2_ex
      # relative to this repo until the Hex package is fixed.
      {:bz2_ex, path: "../bz2_ex", override: true},

      # Dev/test only.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Reticulum Relay Chat (RRC) protocol for Elixir.

    Implements both client and hub roles for the RRC v1 protocol
    (https://rrc.kc1awv.net/), built on top of reticulum_ex. The library
    is platform-neutral: storage, transport, and event handling are
    expressed as behaviors that desktop, mobile, and server applications
    implement for their environment.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "Codeberg" => @source_url,
        "RRC spec" => "https://rrc.kc1awv.net/"
      },
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "RRC",
      source_ref: "v#{@version}",
      extras: ["README.md"],
      groups_for_modules: [
        "Core protocol": [RRC, RRC.Frame, RRC.Room, RRC.Error],
        "Client": [RRC.Client],
        "Hub": [RRC.Hub, RRC.Hub.Session, RRC.Hub.SessionSupervisor, RRC.Hub.RoomRegistry],
        "Behaviors": [RRC.Handler, RRC.Storage, RRC.Transport, RRC.Hub.Moderator],
        "Reference implementations": [
          RRC.Storage.InMemory,
          RRC.Storage.Null,
          RRC.Transport.RNS
        ]
      ]
    ]
  end
end
