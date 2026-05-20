defmodule RRC.Frame do
  @moduledoc """
  RRC envelope codec.

  Every RRC message — HELLO, WELCOME, JOIN, JOINED, PART, PARTED, MSG,
  NOTICE, ACTION, PING, PONG, ERROR — uses the same envelope structure:
  a CBOR map with eight numbered fields.

  This module defines the struct, the message-type constants, and the
  `pack/1` and `unpack/1` functions that turn frames into wire bytes
  and back. It does not touch any networking code — that lives in
  `RRC.Transport` adapters.

  See RRC specification chapter 3 for the wire encoding:
  https://rrc.kc1awv.net/3-RRC-wire-encoding.html

  ## Envelope fields

      0 - version       (uint, always 1 for this spec)
      1 - type          (uint, one of the @-prefixed constants below)
      2 - message_id    (8-byte binary, sender-generated)
      3 - timestamp     (uint, ms since epoch)
      4 - sender        (16-byte RNS identity hash)
      5 - room          (string, optional)
      6 - body          (varies by type, optional)
      7 - nickname      (string, optional, advisory)

  Unknown fields are ignored on decode. Extra fields up to envelope
  key 63 are reserved for protocol extensions.

  ## Message types

  Types are represented as atoms (`:hello`, `:msg`, etc.) in the struct
  and as unsigned integers on the wire. Use `type_code/1` and
  `type_atom/1` to convert.
  """

  @protocol_version 1

  # Message type assignments per spec chapter 3.
  @type_hello 1
  @type_welcome 2
  @type_join 10
  @type_joined 11
  @type_part 12
  @type_parted 13
  @type_msg 20
  @type_notice 21
  @type_action 22
  @type_ping 30
  @type_pong 31
  @type_error 40

  defstruct version: @protocol_version,
            type: nil,
            message_id: nil,
            timestamp: nil,
            sender: nil,
            room: nil,
            body: nil,
            nickname: nil

  @type type ::
          :hello
          | :welcome
          | :join
          | :joined
          | :part
          | :parted
          | :msg
          | :notice
          | :action
          | :ping
          | :pong
          | :error

  @type t :: %__MODULE__{
          version: 1,
          type: type(),
          message_id: <<_::64>>,
          timestamp: non_neg_integer(),
          sender: <<_::128>>,
          room: String.t() | nil,
          body: term(),
          nickname: String.t() | nil
        }

  # ============================================================================
  # Constructors
  # ============================================================================

  @doc """
  Build a new frame.

  Required fields are `type` (atom) and `sender` (16-byte identity hash).
  `message_id` and `timestamp` are auto-generated unless explicitly given;
  pass them in `opts` if you need determinism (tests).

  ## Options

    * `:message_id` - 8-byte binary. Defaults to `:crypto.strong_rand_bytes(8)`.
    * `:timestamp` - ms since epoch. Defaults to `System.system_time(:millisecond)`.
    * `:room` - string room name. Optional.
    * `:body` - message body, type-specific. Optional.
    * `:nickname` - advisory display name. Optional.
  """
  @spec new(type(), <<_::128>>, keyword()) :: t()
  def new(type, sender, opts \\ [])
      when is_atom(type) and is_binary(sender) and byte_size(sender) == 16 do
    %__MODULE__{
      version: @protocol_version,
      type: type,
      message_id: Keyword.get_lazy(opts, :message_id, fn -> :crypto.strong_rand_bytes(8) end),
      timestamp: Keyword.get_lazy(opts, :timestamp, fn -> System.system_time(:millisecond) end),
      sender: sender,
      room: Keyword.get(opts, :room),
      body: Keyword.get(opts, :body),
      nickname: Keyword.get(opts, :nickname)
    }
  end

  # Convenience constructors for each message type. These are sugar over
  # `new/3` but make call sites read clearly. Callers can pass any of the
  # opts new/3 accepts.

  @doc "Build a HELLO frame. `body` may be a CBOR-encodable map with hello fields."
  def hello(sender, opts \\ []), do: new(:hello, sender, opts)

  @doc "Build a WELCOME frame. Hub-side construction."
  def welcome(sender, opts \\ []), do: new(:welcome, sender, opts)

  @doc "Build a JOIN frame for a room. `room` is required."
  def join(sender, room, opts \\ []) when is_binary(room),
    do: new(:join, sender, Keyword.put(opts, :room, room))

  @doc "Build a JOINED frame (hub confirming room entry)."
  def joined(sender, room, opts \\ []) when is_binary(room),
    do: new(:joined, sender, Keyword.put(opts, :room, room))

  @doc "Build a PART frame to leave a room."
  def part(sender, room, opts \\ []) when is_binary(room),
    do: new(:part, sender, Keyword.put(opts, :room, room))

  @doc "Build a PARTED frame (hub confirming departure)."
  def parted(sender, room, opts \\ []) when is_binary(room),
    do: new(:parted, sender, Keyword.put(opts, :room, room))

  @doc "Build an MSG frame carrying chat text. `body` is the message content."
  def msg(sender, room, body, opts \\ []) when is_binary(room) do
    new(:msg, sender, opts |> Keyword.put(:room, room) |> Keyword.put(:body, body))
  end

  @doc "Build a NOTICE frame (informational, no reply expected)."
  def notice(sender, room, body, opts \\ []) when is_binary(room) do
    new(:notice, sender, opts |> Keyword.put(:room, room) |> Keyword.put(:body, body))
  end

  @doc "Build an ACTION frame (IRC-style emote)."
  def action(sender, room, body, opts \\ []) when is_binary(room) do
    new(:action, sender, opts |> Keyword.put(:room, room) |> Keyword.put(:body, body))
  end

  @doc """
  Build a PING frame. Optional `body` is echoed in the PONG.

  Receivers MUST echo body unchanged in their PONG if present.
  """
  def ping(sender, opts \\ []), do: new(:ping, sender, opts)

  @doc "Build a PONG frame. Echoes back the PING's body if present."
  def pong(sender, opts \\ []), do: new(:pong, sender, opts)

  @doc """
  Build an ERROR frame. `body` should be a human-readable string describing
  the error, but may be a CBOR map for structured error info.
  """
  def error(sender, body, opts \\ []),
    do: new(:error, sender, Keyword.put(opts, :body, body))

  # ============================================================================
  # Type code conversions
  # ============================================================================

  @doc "Convert numeric type code to atom. Returns `:unknown` for unrecognized codes."
  @spec type_atom(non_neg_integer()) :: type() | :unknown
  def type_atom(@type_hello), do: :hello
  def type_atom(@type_welcome), do: :welcome
  def type_atom(@type_join), do: :join
  def type_atom(@type_joined), do: :joined
  def type_atom(@type_part), do: :part
  def type_atom(@type_parted), do: :parted
  def type_atom(@type_msg), do: :msg
  def type_atom(@type_notice), do: :notice
  def type_atom(@type_action), do: :action
  def type_atom(@type_ping), do: :ping
  def type_atom(@type_pong), do: :pong
  def type_atom(@type_error), do: :error
  def type_atom(_), do: :unknown

  @doc "Convert atom type to numeric code. Raises for unknown atoms."
  @spec type_code(type()) :: non_neg_integer()
  def type_code(:hello), do: @type_hello
  def type_code(:welcome), do: @type_welcome
  def type_code(:join), do: @type_join
  def type_code(:joined), do: @type_joined
  def type_code(:part), do: @type_part
  def type_code(:parted), do: @type_parted
  def type_code(:msg), do: @type_msg
  def type_code(:notice), do: @type_notice
  def type_code(:action), do: @type_action
  def type_code(:ping), do: @type_ping
  def type_code(:pong), do: @type_pong
  def type_code(:error), do: @type_error

  # ============================================================================
  # Classification helpers
  # ============================================================================

  @doc "True if the frame carries content for a room (MSG, NOTICE, ACTION)."
  @spec room_message?(t()) :: boolean()
  def room_message?(%__MODULE__{type: t}) when t in [:msg, :notice, :action], do: true
  def room_message?(_), do: false

  @doc "True if the frame is a link-control message (HELLO, WELCOME)."
  @spec link_control?(t()) :: boolean()
  def link_control?(%__MODULE__{type: t}) when t in [:hello, :welcome], do: true
  def link_control?(_), do: false

  @doc "True if the frame is a room-membership message (JOIN, JOINED, PART, PARTED)."
  @spec membership?(t()) :: boolean()
  def membership?(%__MODULE__{type: t}) when t in [:join, :joined, :part, :parted], do: true
  def membership?(_), do: false

  # ============================================================================
  # Encoding (frame -> CBOR bytes)
  # ============================================================================

  @doc """
  Encode a frame to CBOR bytes for transmission over a Reticulum Link.

  Returns `{:ok, binary}` on success, `{:error, reason}` if the frame is
  invalid (missing required fields, wrong sizes, unknown type).
  """
  @spec pack(t()) :: {:ok, binary()} | {:error, term()}
  def pack(%__MODULE__{} = frame) do
    with :ok <- validate(frame) do
      map = to_cbor_map(frame)
      {:ok, CBOR.encode(map)}
    end
  end

  @doc "Like `pack/1`, but raises on error."
  @spec pack!(t()) :: binary()
  def pack!(frame) do
    case pack(frame) do
      {:ok, bin} -> bin
      {:error, reason} -> raise ArgumentError, "invalid frame: #{inspect(reason)}"
    end
  end

  defp validate(%__MODULE__{type: nil}), do: {:error, :missing_type}
  defp validate(%__MODULE__{type: t}) when t in [:unknown], do: {:error, :unknown_type}

  defp validate(%__MODULE__{message_id: id}) when not is_binary(id) or byte_size(id) != 8,
    do: {:error, :invalid_message_id}

  defp validate(%__MODULE__{timestamp: ts}) when not is_integer(ts) or ts < 0,
    do: {:error, :invalid_timestamp}

  defp validate(%__MODULE__{sender: s}) when not is_binary(s) or byte_size(s) != 16,
    do: {:error, :invalid_sender}

  defp validate(%__MODULE__{type: t, room: nil}) when t in [:msg, :notice, :action, :join, :joined, :part, :parted],
    do: {:error, :missing_room}

  defp validate(%__MODULE__{}), do: :ok

  defp to_cbor_map(%__MODULE__{} = frame) do
    # Build the CBOR map with only the fields actually present, using
    # integer keys per spec chapter 3. Keys 0-4 are always present;
    # 5/6/7 are conditional.
    #
    # CBOR byte strings are wrapped in %CBOR.Tag{tag: :bytes, value: bin}
    # by the `cbor` library to distinguish them from text strings.
    map = %{
      0 => frame.version,
      1 => type_code(frame.type),
      2 => %CBOR.Tag{tag: :bytes, value: frame.message_id},
      3 => frame.timestamp,
      4 => %CBOR.Tag{tag: :bytes, value: frame.sender}
    }

    map
    |> maybe_put(5, frame.room)
    |> maybe_put(6, encode_body(frame.type, frame.body))
    |> maybe_put(7, frame.nickname)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Body encoding is type-specific. For HELLO/WELCOME the body is a CBOR
  # map; for MSG/NOTICE/ACTION/ERROR it's typically a text string; for
  # everything else it's omitted.
  defp encode_body(_type, nil), do: nil
  defp encode_body(_type, body), do: body

  # ============================================================================
  # Decoding (CBOR bytes -> frame)
  # ============================================================================

  @doc """
  Decode a frame from CBOR bytes.

  Returns `{:ok, frame, rest}` on success — `rest` contains any trailing
  bytes (normally empty for RRC since each Link packet carries one frame).

  Returns `{:error, reason}` if decoding fails or the message is malformed.

  Per spec chapter 3, decoders MUST ignore unknown envelope keys (forward
  compatibility) and MUST ignore unknown message types.
  """
  @spec unpack(binary()) :: {:ok, t(), binary()} | {:error, term()}
  def unpack(data) when is_binary(data) do
    case CBOR.decode(data) do
      {:ok, map, rest} when is_map(map) ->
        case from_cbor_map(map) do
          {:ok, frame} -> {:ok, frame, rest}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _other, _rest} ->
        {:error, :not_a_map}

      {:error, reason} ->
        {:error, {:cbor_decode, reason}}
    end
  end

  @doc "Like `unpack/1`, but raises on error."
  @spec unpack!(binary()) :: {t(), binary()}
  def unpack!(data) do
    case unpack(data) do
      {:ok, frame, rest} -> {frame, rest}
      {:error, reason} -> raise ArgumentError, "decode failed: #{inspect(reason)}"
    end
  end

  defp from_cbor_map(map) do
    with {:ok, version} <- fetch_uint(map, 0, :missing_version),
         :ok <- check_version(version),
         {:ok, type_code} <- fetch_uint(map, 1, :missing_type),
         {:ok, message_id} <- fetch_bytes(map, 2, 8, :invalid_message_id),
         {:ok, timestamp} <- fetch_uint(map, 3, :missing_timestamp),
         {:ok, sender} <- fetch_bytes(map, 4, 16, :invalid_sender) do
      type = type_atom(type_code)
      # Unknown types are not rejected — per spec they MUST be silently
      # ignored. We decode the envelope but mark the type as :unknown
      # so callers can decide what to do.
      {:ok,
       %__MODULE__{
         version: version,
         type: type,
         message_id: message_id,
         timestamp: timestamp,
         sender: sender,
         room: Map.get(map, 5),
         body: decode_body(type, Map.get(map, 6)),
         nickname: Map.get(map, 7)
       }}
    end
  end

  defp check_version(1), do: :ok
  defp check_version(v), do: {:error, {:unsupported_version, v}}

  defp fetch_uint(map, key, err) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, err}
    end
  end

  defp fetch_bytes(map, key, expected_size, err) do
    case Map.get(map, key) do
      %CBOR.Tag{tag: :bytes, value: bin} when byte_size(bin) == expected_size ->
        {:ok, bin}

      bin when is_binary(bin) and byte_size(bin) == expected_size ->
        # Some decoders unwrap bytes automatically.
        {:ok, bin}

      _ ->
        {:error, err}
    end
  end

  defp decode_body(_type, nil), do: nil
  defp decode_body(_type, body), do: body
end
