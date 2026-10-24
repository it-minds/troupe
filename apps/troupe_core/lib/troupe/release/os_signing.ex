defmodule Troupe.Release.OSSigning do
  @moduledoc """
  The operating systems' code signatures on everything a release unpacks.

  Smart App Control and Gatekeeper check every executable and library a program loads, not
  only the file that was downloaded. So the files of `troupe-daemon`'s release are signed
  before `:tar` packs them, and the files of `troupe`'s Burrito payload before Burrito
  wraps them; the binary that results, and the archive, are what the release's manifest
  then names and the release key signs.

  Off unless `TROUPE_SIGN` names the signing script, `scripts/signing/sign-macos.sh` or
  `scripts/signing/sign-windows.ps1`, which `native.yml` sets only for a build it signs.
  Without it a build is exactly what it was. The script is handed the directory, finds
  what to sign there, and reads its identity from the environment.
  """

  @doc "A `mix release` step, between `:assemble` and `:tar`."
  @spec release(Mix.Release.t()) :: Mix.Release.t()
  def release(%Mix.Release{} = release) do
    sign!(release.path, System.get_env("TROUPE_SIGN"))
    release
  end

  @doc """
  A Burrito build step, after its patch phase, once the target's ERTS is in the payload's
  directory and before the build phase packs it.
  """
  @spec execute(%{work_dir: Path.t()}) :: %{work_dir: Path.t()}
  def execute(%{work_dir: dir} = context) do
    sign!(dir, System.get_env("TROUPE_SIGN"))
    context
  end

  @doc """
  Run `signer` over `dir`, raising when it fails; `nil` or `""` signs nothing.
  """
  @spec sign!(Path.t(), String.t() | nil) :: :signed | :unsigned
  def sign!(_dir, signer) when signer in [nil, ""], do: :unsigned

  def sign!(dir, signer) do
    {program, args} = command(signer, dir)
    Mix.shell().info("Signing #{dir} with #{signer}")

    # Without the caller's PSModulePath: one PowerShell's module path handed to the other
    # (pwsh's to Windows PowerShell, say) leaves the signing cmdlets unloadable.
    case System.cmd(program, args,
           env: [{"PSModulePath", nil}],
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :signed
      {_, status} -> Mix.raise("signing #{dir} with #{signer} exited #{status}")
    end
  end

  @doc "The program and arguments that run `signer` over `dir`."
  @spec command(String.t(), Path.t()) :: {String.t(), [String.t()]}
  def command(signer, dir) do
    if Path.extname(signer) == ".ps1" do
      shell =
        Troupe.Executable.find("pwsh") || Troupe.Executable.find("powershell") ||
          Mix.raise("signing: no pwsh or powershell on the PATH to run #{signer}")

      {shell,
       ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", signer, dir]}
    else
      {"sh", [signer, dir]}
    end
  end
end
