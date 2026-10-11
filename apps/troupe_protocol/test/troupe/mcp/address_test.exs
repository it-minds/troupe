Code.require_file("../../../../troupe_core/test/support/fake_mcp.exs", __DIR__)

defmodule Troupe.MCP.AddressTest do
  @moduledoc """
  Where the daemon sends a request for a person's own MCP server and its sign-in
  (Decision 875, issue #618): a name is resolved, every address it answers is checked
  against Decision 856's list, and the request goes to the address that was checked, with
  the name as the `Host` header and the TLS server name. Loopback and the private ranges
  stay open; link-local, the cloud metadata addresses in every spelling and the
  unspecified address do not. Against listeners on loopback, with `:mcp_resolver`
  standing in for DNS.
  """

  # The resolver stand-in is the application environment's, which is the whole VM's.
  use ExUnit.Case, async: false

  alias Troupe.MCP.{Address, Client, Server, Sessions}
  alias Troupe.MCP.Address.Refused
  alias Troupe.Test.FakeMCP

  @moduletag :capture_log

  setup do
    on_exit(fn -> Application.delete_env(:troupe_protocol, :mcp_resolver) end)
    :ok
  end

  # A stand-in for DNS: `answers` by name, a list for each lookup in turn, the last one
  # repeated; every lookup is sent to the test.
  defp resolver(answers) do
    test = self()
    {:ok, counter} = Agent.start_link(fn -> %{} end)

    Application.put_env(:troupe_protocol, :mcp_resolver, fn host ->
      send(test, {:looked_up, host})
      turns = Map.get(answers, host, [[]])

      n =
        Agent.get_and_update(
          counter,
          &{Map.get(&1, host, 0), Map.update(&1, host, 1, fn n -> n + 1 end)}
        )

      Enum.at(turns, n, List.last(turns))
    end)
  end

  defp lookups(host, count \\ 0) do
    receive do
      {:looked_up, ^host} -> lookups(host, count + 1)
    after
      0 -> count
    end
  end

  defp get(url, extra \\ []),
    do: Req.get(url, [retry: false, receive_timeout: 5_000] ++ extra ++ Address.options())

  describe "a name is resolved, and every address it answers is checked" do
    test "a name resolving to 169.254.169.254 is refused, and nothing is sent" do
      resolver(%{"metadata.example.test" => [[{169, 254, 169, 254}]]})

      assert {:error,
              %Refused{
                host: "metadata.example.test",
                address: "169.254.169.254",
                kind: "link-local"
              } =
                refused} = get("http://metadata.example.test/latest/meta-data/")

      assert Exception.message(refused) ==
               "metadata.example.test resolves to 169.254.169.254, a link-local address, and is not called"
    end

    test "the metadata addresses outside link-local, in every spelling, and the unspecified address" do
      for {address, kind} <- [
            {{169, 254, 169, 254}, "link-local"},
            {{0xFE80, 0, 0, 0, 0, 0, 0, 1}, "link-local"},
            {{0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}, "cloud metadata"},
            {{100, 100, 100, 200}, "cloud metadata"},
            {{0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}, "link-local"},
            {{0x64, 0xFF9B, 0, 0, 0, 0, 0x6464, 0x64C8}, "cloud metadata"},
            {{0, 0, 0, 0}, "unspecified"},
            {{0, 0, 0, 0, 0, 0, 0, 0}, "unspecified"}
          ] do
        resolver(%{"bad.example.test" => [[address]]})

        assert {:error, %Refused{kind: ^kind}} = Address.target("bad.example.test"),
               inspect(address)
      end

      for literal <- ~w(169.254.169.254 fe80::1 FD00:EC2:0:0::254 100.100.100.200
                        ::ffff:169.254.169.254 64:ff9b::a9fe:a9fe 0.0.0.0 :: 2852039166) do
        assert {:error, %Refused{resolved: false}} = Address.target(literal), literal
      end

      assert {:error, %Refused{} = refused} = Address.target("100.100.100.200")
      assert Refused.said(refused) == "is a cloud metadata address"
      assert {:error, %Refused{} = refused} = Address.target("0.0.0.0")
      assert Refused.said(refused) == "is the unspecified address"
    end

    test "one refused answer among good ones refuses the name" do
      resolver(%{"mixed.example.test" => [[{203, 0, 113, 7}, {169, 254, 169, 254}]]})
      assert {:error, %Refused{address: "169.254.169.254"}} = Address.target("mixed.example.test")
    end

    test "a private address is allowed: an intranet's servers are there" do
      for address <- [
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {192, 168, 1, 10},
            {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1},
            {100, 64, 0, 1},
            {100, 100, 100, 201}
          ] do
        resolver(%{"intranet.example.test" => [[address]]})
        assert {:ok, ^address} = Address.target("intranet.example.test")
      end

      assert {:ok, {10, 0, 0, 5}} = Address.target("10.0.0.5")
      assert {:ok, {0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x253}} = Address.target("fd00:ec2::253")
    end

    test "a name that resolves to nothing is the lookup's own failure" do
      resolver(%{})

      assert {:error, %Req.TransportError{reason: :nxdomain}} =
               get("http://nowhere.example.test/")
    end
  end

  describe "the request goes to the address that was checked" do
    test "loopback is allowed, by address and by name" do
      server = listen()

      assert {:ok, %{status: 200}} = get("http://127.0.0.1:#{server.port}/a")
      assert_receive {:request, %{path: "/a", host: host}}
      assert host == "127.0.0.1:#{server.port}"

      resolver(%{"mine.example.test" => [[{127, 0, 0, 1}]]})
      assert {:ok, %{status: 200}} = get("http://mine.example.test:#{server.port}/b")
      assert_receive {:request, %{path: "/b", host: host}}
      assert host == "mine.example.test:#{server.port}"
    end

    test "a name that answers loopback to the check and a metadata address after is sent to loopback, asked once" do
      server = listen()

      resolver(%{
        "rebind.example.test" => [[{127, 0, 0, 1}], [{169, 254, 169, 254}]]
      })

      # The `.test` name resolves nowhere but in the stand-in, so the request arriving
      # at all says the connection asked DNS nothing of its own.
      assert {:ok, %{status: 200}} = get("http://rebind.example.test:#{server.port}/once")
      assert_receive {:request, %{path: "/once", host: host}}
      assert host == "rebind.example.test:#{server.port}"
      assert lookups("rebind.example.test") == 1

      # The next request asks again, and is refused there.
      assert {:error, %Refused{address: "169.254.169.254"}} =
               get("http://rebind.example.test:#{server.port}/twice")

      refute_receive {:request, %{path: "/twice"}}, 200
    end

    test "a redirect is checked before it is followed" do
      resolver(%{"metadata.example.test" => [[{169, 254, 169, 254}]]})

      server =
        listen(fn _request -> {307, [{"location", "http://metadata.example.test/token"}], ""} end)

      assert {:error, %Refused{host: "metadata.example.test"}} =
               get("http://127.0.0.1:#{server.port}/start")

      assert_receive {:request, %{path: "/start"}}
    end

    test "TLS checks the certificate against the name, not the address it was sent to" do
      resolver(%{
        "mcp.example.test" => [[{127, 0, 0, 1}]],
        "other.example.test" => [[{127, 0, 0, 1}]]
      })

      {server, cacerts} = listen_tls("mcp.example.test")
      trust = [connect_options: [transport_opts: [cacerts: cacerts]]]

      assert {:ok, %{status: 200}} = get("https://mcp.example.test:#{server.port}/tls", trust)
      assert_receive {:request, %{path: "/tls", host: host}}
      assert host == "mcp.example.test:#{server.port}"

      # The same address under a name the certificate does not carry is refused by TLS.
      assert {:error, %Req.TransportError{reason: {:tls_alert, {:bad_certificate, why}}}} =
               get("https://other.example.test:#{server.port}/tls", trust)

      assert to_string(why) =~ "hostname_check_failed"
      assert to_string(why) =~ "other.example.test"
    end
  end

  describe "a person's own server, through the MCP client" do
    test "every request of a session goes to the address checked, with the server's name" do
      fake = FakeMCP.start(self())
      on_exit(fn -> FakeMCP.stop(fake) end)
      resolver(%{"notes.example.test" => [[{127, 0, 0, 1}]]})
      {:ok, holder} = Sessions.start_link()

      server =
        Server.from_config(%{
          "name" => "notes",
          "url" => "http://notes.example.test:#{fake.port}/mcp"
        })
        |> Map.merge(%{pinned: true, sessions: Sessions.table(holder)})

      assert {:ok, [%{"name" => "search"}]} = Client.list_tools(server)
      GenServer.stop(holder)

      requests = drain_mcp()

      assert Enum.map(requests, &(&1.rpc || &1.method)) ==
               ["initialize", "notifications/initialized", "tools/list", "DELETE"]

      assert Enum.all?(requests, &(&1.headers["host"] == "notes.example.test:#{fake.port}"))
    end

    test "a server whose name resolves to a metadata address is not called, and says why" do
      resolver(%{"notes.example.test" => [[{100, 100, 100, 200}]]})

      server =
        Server.from_config(%{"name" => "notes", "url" => "https://notes.example.test/mcp"})
        |> Map.put(:pinned, true)

      assert Client.list_tools(server) ==
               {:error,
                "notes.example.test resolves to 100.100.100.200, a cloud metadata address, and is not called"}
    end
  end

  defp drain_mcp(acc \\ []) do
    receive do
      {:fake_mcp, request} -> drain_mcp([request | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  # -- listeners ----------------------------------------------------------------

  # One HTTP/1.1 server on loopback that sends each request's path and `Host` to the test
  # and answers `answer.(request)`, `200` with an empty object by default.
  defp listen(answer \\ fn _request -> {200, [{"content-type", "application/json"}], "{}"} end) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listener)
    serve(listener, port, :gen_tcp, answer)
  end

  defp listen_tls(name) do
    %{server_config: server, client_config: client} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [digest: :sha256, key: {:namedCurve, :secp256r1}],
          intermediates: [],
          peer: [
            digest: :sha256,
            key: {:namedCurve, :secp256r1},
            extensions: [
              {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(name)}]}
            ]
          ]
        },
        client_chain: %{
          root: [digest: :sha256, key: {:namedCurve, :secp256r1}],
          intermediates: [],
          peer: [digest: :sha256, key: {:namedCurve, :secp256r1}]
        }
      })

    {:ok, listener} =
      :ssl.listen(
        0,
        [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}, reuseaddr: true] ++
          Keyword.take(server, [:cert, :key, :cacerts])
      )

    {:ok, {_ip, port}} = :ssl.sockname(listener)

    answer = fn _request -> {200, [{"content-type", "application/json"}], "{}"} end
    {serve(listener, port, :ssl, answer), client[:cacerts]}
  end

  defp serve(listener, port, transport, answer) do
    test = self()

    acceptor =
      spawn(fn ->
        receive do
          :go -> accept(listener, transport, test, answer)
        end
      end)

    :ok = controlling(transport, listener, acceptor)
    send(acceptor, :go)

    on_exit(fn -> transport.close(listener) end)
    %{port: port}
  end

  defp controlling(:gen_tcp, listener, pid), do: :gen_tcp.controlling_process(listener, pid)
  defp controlling(:ssl, listener, pid), do: :ssl.controlling_process(listener, pid)

  defp accept(listener, transport, test, answer) do
    case accepted(listener, transport) do
      {:ok, :refused} ->
        accept(listener, transport, test, answer)

      {:ok, socket} ->
        handle(socket, transport, test, answer)
        accept(listener, transport, test, answer)

      {:error, _closed} ->
        :ok
    end
  end

  # A TLS client that refuses the certificate leaves nothing to answer.
  defp accepted(listener, :gen_tcp), do: :gen_tcp.accept(listener)

  defp accepted(listener, :ssl) do
    with {:ok, socket} <- :ssl.transport_accept(listener) do
      case :ssl.handshake(socket, 5_000) do
        {:ok, socket} -> {:ok, socket}
        {:error, _alert} -> {:ok, :refused}
      end
    end
  end

  defp handle(socket, transport, test, answer) do
    with {:ok, head} <- read_head(socket, transport, "") do
      [request_line | header_lines] = String.split(head, "\r\n", trim: true)
      [_method, path | _] = String.split(request_line, " ")

      headers =
        Map.new(header_lines, fn line ->
          [name, value] = String.split(line, ":", parts: 2)
          {String.downcase(name), String.trim(value)}
        end)

      request = %{path: path, host: headers["host"]}
      send(test, {:request, request})
      {status, response_headers, body} = answer.(request)

      response =
        "HTTP/1.1 #{status} X\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n" <>
          Enum.map_join(response_headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <> "\r\n" <> body

      transport.send(socket, response)
    end

    transport.close(socket)
  end

  defp read_head(socket, transport, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, _rest] ->
        {:ok, head}

      [_partial] ->
        case transport.recv(socket, 0, 5_000) do
          {:ok, data} -> read_head(socket, transport, acc <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
