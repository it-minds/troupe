defmodule Troupe.Plane.ContentSecurityPolicyTest do
  @moduledoc """
  Every response from the plane's host carries a Content-Security-Policy under which no
  script runs but the plane's own files (#460, Decision 803).

  Why it matters: the web app keeps the local daemon's WebSocket token in `localStorage`,
  and the daemon admits this host's origin (Decision 797). Any script that ran on any page
  of this origin, the console's and the front page's as much as the app's, could read the
  token and drive the person's daemon, which runs tools on their machine. What keeps that
  safe is that nothing but the plane's and the app's own code ever runs here, and this is
  where that is held: the header on every kind of response the endpoint gives, and the
  documents it serves needing nothing the header refuses.

  Over a real socket against the running endpoint rather than the bare `Router`, because
  the static files, the console's router and a 404 are all the endpoint's, and a header
  set in one router would leave the others without it. The app at `/app/` is the GUI
  image's own server; its copy of the policy is checked by the GUI's
  `content-security-policy.test.tsx`.
  """

  use Troupe.Plane.DataCase, async: false

  alias Phoenix.HTML.Safe
  alias Troupe.Plane.Web.{Docs, Endpoint, ErrorHTML, Index}
  alias Troupe.Plane.Web.Live.Root

  @moduletag timeout: 60_000

  setup do
    {:ok, {_address, port}} = Endpoint.server_info(:http)

    previous = Application.get_env(:troupe_plane, :oidc)

    Application.put_env(:troupe_plane, :oidc,
      issuer: "https://issuer.example.test",
      client_id: "troupe",
      authorization_endpoint: "https://issuer.example.test/authorize",
      device_authorization_endpoint: "https://issuer.example.test/device",
      token_endpoint: "https://issuer.example.test/token"
    )

    Application.put_env(:troupe_plane, :breakglass, token: "a-break-glass-token-for-tests")

    on_exit(fn ->
      Application.put_env(:troupe_plane, :oidc, previous)
      Application.delete_env(:troupe_plane, :breakglass)
    end)

    %{url: "http://127.0.0.1:#{port}"}
  end

  # One of each kind of response this host gives: the front door, its static files, the
  # API's answers and refusals, a 404, the console's own files, its sign-in redirect, a
  # LiveView route without a session, and the pages the sign-in renders itself.
  @responses [
    {:get, "/", 200},
    {:get, "/docs", 200},
    {:get, "/static/theme.css", 200},
    {:get, "/static/brand/favicon.svg", 200},
    {:get, "/healthz", 200},
    {:get, "/.well-known/troupe", 200},
    {:get, "/.well-known/oauth-protected-resource", 200},
    {:post, "/rpc", 401},
    {:post, "/mcp", 401},
    {:get, "/no-such-page", 404},
    {:get, "/admin/static/app.js", 200},
    {:get, "/admin/static/console.css", 200},
    {:get, "/admin/login", 302},
    {:get, "/admin", 302},
    {:get, "/admin/denied", 200},
    {:get, "/admin/breakglass", 200}
  ]

  describe "the header" do
    test "is on every kind of response the host gives, and is one policy", context do
      for {method, path, status} <- @responses do
        response = request(context, method, path)

        assert response.status == status,
               "#{method} #{path} answered #{response.status}, not #{status}"

        assert length(Req.Response.get_header(response, "content-security-policy")) == 1,
               "#{method} #{path} has no Content-Security-Policy, or more than one"
      end

      policies =
        for {method, path, _status} <- @responses,
            do: context |> request(method, path) |> csp_header()

      assert length(Enum.uniq(policies)) == 1,
             "the host answers with more than one policy: #{inspect(Enum.uniq(policies))}"
    end

    test "runs no script but this origin's own files", context do
      policy = context |> request(:get, "/") |> policy()

      assert policy["script-src"] == ["'self'"],
             "script-src is #{inspect(policy["script-src"])}: no inline script, no eval, " <>
               "no hash or nonce and no other origin"

      # `default-src` is what `script-src-elem`, `script-src-attr` and `worker-src` fall
      # back to through `script-src`, and what every directive not named falls back to.
      assert policy["default-src"] == ["'self'"]
      refute Map.has_key?(policy, "script-src-elem")
      refute Map.has_key?(policy, "script-src-attr")

      for {directive, sources} <- policy, source <- sources do
        refute source in ["'unsafe-eval'", "'wasm-unsafe-eval'", "'unsafe-hashes'", "*"],
               "#{directive} allows #{source}"

        refute String.starts_with?(source, "'nonce-") or String.starts_with?(source, "'sha"),
               "#{directive} allows #{source}"
      end
    end

    test "is not framed, embeds no plugin, and has no base to rewrite", context do
      policy = context |> request(:get, "/docs") |> policy()

      assert policy["frame-ancestors"] == ["'none'"]
      assert policy["object-src"] == ["'none'"]
      assert policy["base-uri"] == ["'none'"]
      assert policy["form-action"] == ["'self'"]
    end

    test "connects to this host and nowhere else", context do
      # The plane's own pages talk to the plane: the console's LiveView socket and nothing
      # besides. The daemon's loopback is the app's to reach, under the app's own policy.
      assert context |> request(:get, "/admin/login") |> policy() |> Map.get("connect-src") ==
               ["'self'"]
    end

    test "styles and fonts come from this host, and the webfonts from their one host",
         context do
      policy = context |> request(:get, "/") |> policy()

      assert policy["style-src"] == ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"]
      assert policy["font-src"] == ["'self'", "https://fonts.gstatic.com"]
      assert policy["img-src"] == ["'self'"]
    end

    test "no response here can be read as a script it is not", context do
      for {method, path, _status} <- @responses do
        response = request(context, method, path)

        assert Req.Response.get_header(response, "x-content-type-options") == ["nosniff"],
               "#{method} #{path} lets a browser sniff its type"
      end
    end
  end

  # The other half of "the pages still work under it": a policy that refuses inline script
  # is only safe to send if no page needs any. Every HTML document this host serves is
  # checked for a `<script>` with a body, an event-handler attribute and a `javascript:`
  # URL, and every script it loads must be this origin's.
  describe "the documents" do
    test "the front door and the sign-in pages carry no inline script", context do
      for path <- ["/", "/docs", "/admin/denied", "/admin/breakglass"] do
        assert_no_inline_script(path, request(context, :get, path).body)
      end
    end

    test "the console's document carries no inline script" do
      document =
        %{inner_content: {:safe, "<main></main>"}}
        |> Root.root()
        |> Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert_no_inline_script("the console's root", document)
    end

    test "the error page carries no inline script" do
      assert_no_inline_script("the 500 page", ErrorHTML.render("500.html", %{}))
    end

    test "the webfonts are switched on by a file this host serves", context do
      opts = [name: "a plane", url: "https://plane.example.test", app_url: "/app"]

      for document <- [Index.render(opts), Docs.render(opts)] do
        assert document =~ ~s(<script defer src="/static/webfonts.js"></script>)
        assert document =~ ~s(data-webfonts)
      end

      response = request(context, :get, "/static/webfonts.js")
      assert response.status == 200
      assert response.body =~ "data-webfonts"
    end
  end

  defp assert_no_inline_script(where, html) do
    scripts = Regex.scan(~r{<script\b([^>]*)>(.*?)</script>}is, html, capture: :all_but_first)

    for [attributes, body] <- scripts do
      assert String.trim(body) == "",
             "#{where} has an inline script: #{String.slice(body, 0, 80)}"

      src =
        case Regex.run(~r{\bsrc="([^"]+)"}, attributes) do
          [_all, src] -> src
          nil -> ""
        end

      assert String.starts_with?(src, "/") and not String.starts_with?(src, "//"),
             "#{where} loads a script that is not this origin's: #{inspect(attributes)}"
    end

    refute html =~ ~r{\son[a-z]+\s*=}i, "#{where} has an event-handler attribute"
    refute html =~ ~r{javascript:}i, "#{where} has a javascript: URL"
  end

  defp request(context, method, path) do
    {:ok, response} =
      Req.request(
        method: method,
        url: context.url <> path,
        redirect: false,
        retry: false,
        decode_body: false
      )

    response
  end

  defp csp_header(response) do
    [policy] = Req.Response.get_header(response, "content-security-policy")
    policy
  end

  # `default-src 'self'; script-src 'self'` as `%{"default-src" => ["'self'"], ...}`.
  defp policy(response) do
    response
    |> csp_header()
    |> String.split(";", trim: true)
    |> Enum.map(&String.split(&1, ~r/\s+/, trim: true))
    |> Enum.reject(&(&1 == []))
    |> Map.new(fn [directive | sources] -> {String.downcase(directive), sources} end)
  end
end
