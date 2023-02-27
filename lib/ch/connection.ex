defmodule Ch.Connection do
  @moduledoc false
  use DBConnection
  alias Ch.{Error, RowBinary}
  alias Mint.HTTP1, as: HTTP

  @impl true
  def connect(opts) do
    scheme = String.to_existing_atom(opts[:scheme] || "http")
    address = opts[:hostname] || "localhost"
    port = opts[:port] || 8123

    with {:ok, conn} <- HTTP.connect(scheme, address, port, mode: :passive) do
      conn =
        conn
        |> HTTP.put_private(:timeout, opts[:timeout] || :timer.seconds(15))
        |> maybe_put_private(:database, opts[:database])
        |> maybe_put_private(:username, opts[:username])
        |> maybe_put_private(:password, opts[:password])
        |> maybe_put_private(:settings, opts[:settings])

      {:ok, conn}
    end
  end

  @impl true
  def ping(conn) do
    with {:ok, conn, ref} <- request(conn, "GET", "/ping", _headers = [], _body = ""),
         {:ok, conn, _responses} <- receive_stream(conn, ref),
         do: {:ok, conn}
  end

  @impl true
  def checkout(conn) do
    {:ok, conn}
  end

  @impl true
  def handle_begin(_opts, conn) do
    {:ok, %{}, conn}
  end

  @impl true
  def handle_commit(_opts, conn) do
    {:ok, %{}, conn}
  end

  @impl true
  def handle_rollback(_opts, conn) do
    {:ok, %{}, conn}
  end

  @impl true
  def handle_status(_opts, conn) do
    {:idle, conn}
  end

  @impl true
  def handle_prepare(query, _opts, conn) do
    {:ok, query, conn}
  end

  @impl true
  # TODO instead of command == :insert, do rows is stream check
  def handle_execute(%Ch.Query{command: :insert} = query, rows, opts, conn) do
    %Ch.Query{statement: statement} = query
    path = "/?" <> URI.encode_query(get_settings(conn, opts))

    statement =
      if format = Keyword.get(opts, :format) do
        [statement, " FORMAT ", format, ?\n]
      else
        [statement, ?\n]
      end

    with {:ok, conn, ref} <- request(conn, "POST", path, headers(conn, opts), :stream),
         {:ok, conn} <- stream_body(conn, ref, statement, rows),
         {:ok, conn, responses} <- receive_stream(conn, ref) do
      [_status, headers | _data] = responses
      num_rows = get_summary(headers, "written_rows")
      {:ok, query, build_response(num_rows, _rows = []), conn}
    end
  end

  def handle_execute(query, params, opts, conn) do
    %Ch.Query{statement: statement} = query

    types = Keyword.get(opts, :types)
    default_format = if types, do: "RowBinary", else: "RowBinaryWithNamesAndTypes"
    format = Keyword.get(opts, :format) || default_format

    params = build_params(params) ++ get_settings(conn, opts)
    path = "/?" <> URI.encode_query(params)

    headers = [{"x-clickhouse-format", format} | headers(conn, opts)]

    with {:ok, conn, ref} <- request(conn, "POST", path, headers, statement),
         {:ok, conn, responses} <- receive_stream(conn, ref, opts) do
      [_status, headers | data] = responses

      response =
        case get_header(headers, "x-clickhouse-format") do
          "RowBinary" ->
            rows = data |> IO.iodata_to_binary() |> RowBinary.decode_rows(types)
            build_response(rows)

          "RowBinaryWithNamesAndTypes" ->
            rows = data |> IO.iodata_to_binary() |> RowBinary.decode_rows()
            build_response(rows)

          _other ->
            build_response(data)
        end

      {:ok, query, response, conn}
    end
  end

  defp build_response(rows) do
    build_response(length(rows), rows)
  end

  defp build_response(num_rows, rows) do
    %{num_rows: num_rows, rows: rows}
  end

  @impl true
  def handle_close(_query, _opts, conn) do
    {:ok, _result = nil, conn}
  end

  @impl true
  def handle_declare(_query, _params, _opts, conn) do
    {:error, Error.exception("cursors are not supported"), conn}
  end

  @impl true
  def handle_fetch(_query, _cursor, _opts, conn) do
    {:error, Error.exception("cursors are not supported"), conn}
  end

  @impl true
  def handle_deallocate(_query, _cursor, _opts, conn) do
    {:error, Error.exception("cursors are not supported"), conn}
  end

  @impl true
  def disconnect(_error, conn) do
    {:ok = ok, _conn} = HTTP.close(conn)
    ok
  end

  defp maybe_put_private(conn, _k, nil), do: conn
  defp maybe_put_private(conn, k, v), do: HTTP.put_private(conn, k, v)

  defp get_opts_or_private(conn, opts, key) do
    opts[key] || HTTP.get_private(conn, key)
  end

  defp get_settings(conn, opts) do
    default_settings = HTTP.get_private(conn, :settings, [])
    opts_settings = Keyword.get(opts, :settings, [])
    Keyword.merge(default_settings, opts_settings)
  end

  defp headers(conn, opts) do
    []
    |> maybe_put_header("x-clickhouse-user", get_opts_or_private(conn, opts, :username))
    |> maybe_put_header("x-clickhouse-key", get_opts_or_private(conn, opts, :password))
    |> maybe_put_header("x-clickhouse-database", get_opts_or_private(conn, opts, :database))
  end

  defp maybe_put_header(headers, _k, nil), do: headers
  defp maybe_put_header(headers, k, v), do: [{k, v} | headers]

  # @compile inline: [request: 5]
  defp request(conn, method, path, headers, body) do
    case HTTP.request(conn, method, path, headers, body) do
      {:ok, _conn, _ref} = ok -> ok
      {:error, _conn, _reason} = error -> disconnect(error)
    end
  end

  def stream_body(conn, ref, statement, data) do
    stream = Stream.concat([[statement], data, [:eof]])

    Enum.reduce_while(stream, {:ok, conn}, fn
      chunk, {:ok, conn} -> {:cont, HTTP.stream_request_body(conn, ref, chunk)}
      _chunk, error -> {:halt, disconnect(error)}
    end)
  end

  defp receive_stream(conn, ref, opts \\ []) do
    case receive_stream(conn, ref, [], opts) do
      {:ok, _conn, [200 | _rest]} = ok ->
        ok

      {:ok, conn, [_status, headers | data]} ->
        error = IO.iodata_to_binary(data)
        exception = Error.exception(error)

        code =
          if code = get_header(headers, "x-clickhouse-exception-code") do
            String.to_integer(code)
          end

        exception = %{exception | code: code}
        {:error, exception, conn}

      {:error, _conn, _error, _responses} = error ->
        disconnect(error)
    end
  end

  @typep response :: Mint.Types.status() | Mint.Types.headers() | binary

  @spec receive_stream(HTTP.t(), reference, [response], Keyword.t()) ::
          {:ok, HTTP.t(), [response]}
          | {:error, HTTP.t(), Mint.Types.error(), [response]}
  defp receive_stream(conn, ref, acc, opts) do
    timeout = opts[:timeout] || HTTP.get_private(conn, :timeout)

    case HTTP.recv(conn, 0, timeout) do
      {:ok, conn, responses} ->
        case handle_responses(responses, ref, acc) do
          {:ok, responses} -> {:ok, conn, responses}
          {:more, acc} -> receive_stream(conn, ref, acc, opts)
        end

      {:error, _conn, _reason, responses} = error ->
        put_elem(error, 3, acc ++ responses)
    end
  end

  defp get_header(headers, key) do
    case List.keyfind(headers, key, 0) do
      {_, value} -> value
      nil = not_found -> not_found
    end
  end

  # TODO telemetry?
  defp get_summary(headers) do
    if summary = get_header(headers, "x-clickhouse-summary") do
      Jason.decode!(summary)
    end
  end

  defp get_summary(headers, key) do
    if summary = get_summary(headers) do
      if value = Map.get(summary, key) do
        String.to_integer(value)
      end
    end
  end

  # TODO wrap errors in Ch.Error?
  @spec disconnect({:error, HTTP.t(), Mint.Types.error(), [response]}) ::
          {:disconnect, Mint.Types.error(), HTTP.t()}
  defp disconnect({:error, conn, error, _responses}) do
    {:disconnect, error, conn}
  end

  @spec disconnect({:error, HTTP.t(), Mint.Types.error()}) ::
          {:disconnect, Mint.Types.error(), HTTP.t()}
  defp disconnect({:error, conn, error}) do
    {:disconnect, error, conn}
  end

  # TODO handle rest
  defp handle_responses([{:done, ref}], ref, acc) do
    {:ok, :lists.reverse(acc)}
  end

  defp handle_responses([{tag, ref, data} | rest], ref, acc)
       when tag in [:data, :status, :headers] do
    handle_responses(rest, ref, [data | acc])
  end

  defp handle_responses([], _ref, acc), do: {:more, acc}

  defp build_params(params) when is_map(params) do
    Enum.map(params, fn {k, v} -> {"param_#{k}", encode_param(v)} end)
  end

  defp build_params(params) when is_list(params) do
    params
    |> Enum.with_index()
    |> Enum.map(fn {v, idx} -> {"param_$#{idx}", encode_param(v)} end)
  end

  defp encode_param(n) when is_integer(n), do: Integer.to_string(n)
  defp encode_param(f) when is_float(f), do: Float.to_string(f)
  defp encode_param(b) when is_binary(b), do: b
  defp encode_param(%Decimal{} = d), do: Decimal.to_string(d, :normal)

  defp encode_param(%Date{} = date), do: date

  defp encode_param(%NaiveDateTime{} = naive) do
    NaiveDateTime.to_iso8601(naive)
  end

  defp encode_param(%DateTime{} = dt) do
    dt |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
  end

  defp encode_param(a) when is_list(a) do
    IO.iodata_to_binary([?[, encode_array_params(a), ?]])
  end

  defp encode_array_params([last]), do: encode_array_param(last)

  defp encode_array_params([s | rest]) do
    [encode_array_param(s), ?, | encode_array_params(rest)]
  end

  defp encode_array_params([] = empty), do: empty

  defp encode_array_param(s) when is_binary(s) do
    [?', to_iodata(s, 0, s, []), ?']
  end

  defp encode_array_param(v) do
    encode_param(v)
  end

  # TODO
  # escapes = [
  #   {?_, "\_"},
  #   {?', "''"},
  #   {?%, "\%"},
  #   {?\\, "\\\\"}
  # ]

  escapes = [
    {?', "\\'"},
    {?\\, "\\\\"}
  ]

  @dialyzer {:no_improper_lists, to_iodata: 4, to_iodata: 5}

  @doc false
  # based on based on https://github.com/elixir-plug/plug/blob/main/lib/plug/html.ex#L41-L80
  def to_iodata(binary, skip, original, acc)

  for {match, insert} <- escapes do
    def to_iodata(<<unquote(match), rest::bits>>, skip, original, acc) do
      to_iodata(rest, skip + 1, original, [acc | unquote(insert)])
    end
  end

  def to_iodata(<<_char, rest::bits>>, skip, original, acc) do
    to_iodata(rest, skip, original, acc, 1)
  end

  def to_iodata(<<>>, _skip, _original, acc) do
    acc
  end

  for {match, insert} <- escapes do
    defp to_iodata(<<unquote(match), rest::bits>>, skip, original, acc, len) do
      part = binary_part(original, skip, len)
      to_iodata(rest, skip + len + 1, original, [acc, part | unquote(insert)])
    end
  end

  defp to_iodata(<<_char, rest::bits>>, skip, original, acc, len) do
    to_iodata(rest, skip, original, acc, len + 1)
  end

  defp to_iodata(<<>>, 0, original, _acc, _len) do
    original
  end

  defp to_iodata(<<>>, skip, original, acc, len) do
    [acc | binary_part(original, skip, len)]
  end
end
