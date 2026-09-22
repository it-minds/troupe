defmodule Troupe.Plane.Web.Docs do
  @moduledoc """
  The page at `/docs`: what Troupe is, for the person who was handed the URL.

  `/` answers "what is this host and how do I point something at it". This answers the
  question underneath that one — what a session, a profile and an approval actually are —
  and it answers it in pictures, because the reader it is written for has not decided to
  read anything yet.

  ## What is on it, and what deliberately is not

  The documentation suite under `docs/` is four tracks, a whitepaper and an audit: about
  four hundred kilobytes of prose, correct and cited and far too much to hand somebody
  who wants to know whether to click. This page is the front of it, chosen rather than
  summarised:

  * the map, the session lifecycle, the approval, the plane's row beside the pod's log,
    and the three steps of a sign-in — `Troupe.Plane.Web.Diagrams`;
  * the nine words from `docs/user/overview.md` a person meets in the first hour;
  * the four sentences from the same file that begin "it never", which are the trust
    story and were three screens down;
  * the same three install steps as `/`, written against this plane's URL.

  **Not on it, on purpose.** This page has no authentication in front of it, so the line
  is a disclosure boundary and not only an editorial one: nothing from
  `docs/history/AUDIT.md` (open questions and findings), nothing from
  `docs/admin/configuration.md` (the environment and Helm inventory), no
  roles-and-permissions detail, and none of the developer track. The endpoint table on `/`
  is the whole of the surface either page names, and it named all of it before.

  ## Why it does not read like the markdown it came from

  Because that is the failure mode it was written against. Rendered markdown is headings
  and paragraphs and tables stacked in one column, with code blocks for texture and a
  `Sources:` footer — and the suite's own audit banners on top of that. So the unit here
  is a figure: a picture, then one caption carrying the sentence the picture makes, and
  no paragraph underneath restating the drawing. The glossary is a grid of terms rather
  than a definition list. There is no table on the page at all.

  Commands are written against this plane's own URL for the same reason they are on `/`:
  a command a reader can copy is worth more than one they have to adapt.
  """

  alias Troupe.Plane.Web.{Diagrams, Page}

  @doc """
  The document, as a string.

  `:url` is this plane's base URL, which the install steps are written against.
  `:app_url` is where the GUI is mounted, or `nil`; the last step offers the browser only
  when there is a browser to offer.
  """
  @spec render(keyword()) :: String.t()
  def render(opts) do
    name = Keyword.get(opts, :name, "troupe")
    url = Keyword.fetch!(opts, :url)
    app_url = Keyword.get(opts, :app_url)

    Page.render(
      title: "What Troupe is — #{name}",
      description:
        "Where your work runs, what survives a closed laptop, where an agent stops to ask you, and what this host keeps about you — in five pictures.",
      og_description: "Five pictures and a glossary.",
      url: url,
      name: name,
      nav: :docs,
      # The reserved colour's rules arrive with the one figure licensed to use it, rather
      # than from the shell — so `/`, which draws no approval, has no reference to the hue.
      extra_css: Diagrams.approval_css(),
      body: body(url, app_url)
    )
  end

  defp body(url, app_url) do
    """
      <p class="eyebrow">What Troupe is</p>
      <h1>Five pictures and a glossary</h1>
      <p class="lede stack-lede">
        Enough to know what you are looking at before you run anything: where your work
        actually happens, what survives a closed laptop, where the agent stops and waits
        for you, and what this host keeps about you. Everything here is the short
        version — <a href="/">this plane's page</a> has the commands.
      </p>

      <h2>Where your work actually runs</h2>
      #{Diagrams.figure(Diagrams.map(), map_caption())}

      <h2>A session outlives your terminal</h2>
      #{Diagrams.figure(Diagrams.lifecycle(), lifecycle_caption())}

      <h2>Nothing runs past you</h2>
      #{Diagrams.figure(Diagrams.approval(), approval_caption())}

      <h2>What we keep, and what we never see</h2>
      #{Diagrams.figure(Diagrams.privacy(), privacy_caption())}

      #{promises()}

      <h2>Signing in</h2>
      #{Diagrams.figure(Diagrams.signin(), signin_caption())}

      <h2>Words you will meet</h2>
      <div class="glossary">
        #{terms()}
      </div>

      <h2>Start in one minute</h2>

      <div class="steps">
        #{Page.step("Step one", "Get the binary", binary_step())}
        #{Page.step("Step two", "Log in, once", login_step(url))}
        #{Page.step("Step three", "Give it something to do", run_step(app_url))}
      </div>

      <p class="note stack-note">
        Every command, every endpoint and the full client API are on
        <a href="/">this plane's own page</a>.
      </p>
    """
  end

  # -- the captions -----------------------------------------------------------

  # Each is the one sentence its picture is making, said once. If a caption starts
  # explaining the drawing rather than the point, the drawing is wrong.

  defp map_caption do
    """
    <b>The plane is a switchboard, not a middleman.</b> It knows who you are and which
        pod you may use, and it hands your client an address and a short-lived token.
        After that your client talks to the pod directly — every message, every file,
        every command the agent runs goes down that line and never touches this host.
    """
  end

  defp lifecycle_caption do
    """
    <b>Closing the window does not stop the work.</b> The session is a process on a pod,
        not a tab: it keeps going while you walk away, and when it has been idle a while
        it seals itself and sleeps. Open it tomorrow from a different laptop and you are
        looking at the same transcript from the same place you left it.
    """
  end

  defp approval_caption do
    """
    <b>Reading is free; changing things is not.</b> The agent reads, searches and thinks
        without interrupting you. The moment it wants to write a file or run a shell
        command it stops that one call and waits — and an unattended session waits too.
        There is no mode on this server that answers for you.
    """
  end

  defp privacy_caption do
    """
    <b>There is no admin button that shows someone your session.</b> Not a permission
        that was withheld — there is no method on this platform that returns session
        content at all. An administrator can see that you ran something, on which profile,
        and what it cost. What it said is in a log encrypted to keys the plane cannot use.
    """
  end

  defp signin_caption do
    """
    <b>One account, your company's.</b> Troupe does not have a password of its own and
        never asks for one. You sign in where you always sign in; the plane checks the
        signature and issues a token that expires in a quarter of an hour. Your teams come
        from the identity provider too — nobody edits membership here.
    """
  end

  # -- the promises -----------------------------------------------------------

  @promises [
    {"It never reads your session",
     "The plane holds metadata. The transcript lives in the pod's log and in storage only pods can open."},
    {"It never writes where you can't see",
     "Every file change goes through a tool that is either an approval prompt or a durable event in the log."},
    {"It never approves its own commands",
     "An unattended session waits for a person, or is configured to deny. There is no server-side \"auto\"."},
    {"It never uses your machine unasked",
     "Offering your own tool server takes a second, deliberate confirmation, and everyone on the session sees it."}
  ]

  defp promises do
    items =
      Enum.map_join(@promises, "\n", fn {heading, what} ->
        """
        <div class="promise">
              <h3>#{Page.e(heading)}</h3>
              <p>#{Page.e(what)}</p>
            </div>
        """
      end)

    """
    <div class="promises">
        #{items}
      </div>
    """
  end

  # -- the glossary -----------------------------------------------------------

  # The nine from `docs/user/overview.md` § "Words you will meet", cut to a card each.
  # Anything that needed a second paragraph there was either shortened until it did not
  # or left out; a glossary a person will not finish is not a glossary.
  @terms [
    {"Plane",
     "The server your team signs in to. It knows who you are, which teams you are in, and where every session is running. Never what one said."},
    {"Team",
     "A group from your company's identity provider that an administrator has enabled here. It carries a budget, a retention period and a list of profiles."},
    {"Profile",
     "A kind of worker pod: an image, a model, some tools, some storage. Sessions are created on one. If you only have one, you never have to name it."},
    {"Session",
     "One agent working in one directory, with a durable log of everything that happened. Active, dormant, read-only or erased."},
    {"Agent",
     "The thing that talks to the model. A session starts with one — <code>build</code>, or <code>plan</code> if you want a proposal first — and it can delegate to others."},
    {"Approval",
     "The moment a tool stops and asks. Anyone attached with control rights can answer; the first answer wins and everybody is told who gave it."},
    {"Budget",
     "Limits on turns, tokens and wall-clock time, plus your team's money budget. When one is reached the agent stops and says which. It never quietly continues."},
    {"Bundle",
     "The configuration a profile's sessions carry — agents, skills and tool servers — published in versions. Your session is pinned to the one current when it started."},
    {"Trigger",
     "A scheduled or externally fired job that starts a session on its own. Sessions made this way are flagged for review until somebody looks at them."}
  ]

  # The definitions carry their own `<code>` markup, so they are written here rather than
  # escaped; nothing in them comes from outside this file.
  defp terms do
    Enum.map_join(@terms, "\n", fn {term, what} ->
      ~s(<dl class="term"><dt>#{Page.e(term)}</dt><dd>#{what}</dd></dl>)
    end)
  end

  # -- the three steps --------------------------------------------------------

  defp binary_step do
    """
    <p>
        One executable, nothing alongside it. Ask your administrator where your
        organisation publishes it.
      </p>
    """
  end

  defp login_step(url) do
    """
    #{Page.pre("troupe login " <> url)}
      <p>
        A code to type in your browser. A refresh token lands in your config directory;
        nothing else is stored.
      </p>
    """
  end

  defp run_step(app_url) do
    """
    #{Page.pre(~s(troupe --remote run "fix the flaky test"))}
      #{run_step_tail(app_url)}
    """
  end

  defp run_step_tail(nil),
    do: ~s(<p>Or <code>troupe --remote</code> for the full terminal UI.</p>)

  defp run_step_tail(app_url) do
    ~s(<p>Or open <a href="#{Page.e(app_url)}">the app</a> and do the same thing in a browser.</p>)
  end
end
