defmodule Troupe.Reaper do
  @moduledoc "Locates the `reaper` helper binary for the running host."

  @spec target() :: String.t()
  def target do
    os =
      case :os.type() do
        {:unix, :darwin} -> "macos"
        {:unix, _} -> "linux"
        {:win32, _} -> "windows"
      end

    arch = to_string(:erlang.system_info(:system_architecture))
    cpu = if arch =~ ~r/aarch64|arm64/, do: "aarch64", else: "x86_64"
    "#{os}_#{cpu}"
  end

  @spec path() :: {:ok, String.t()} | {:error, :reaper_missing}
  def path do
    ext = if match?({:win32, _}, :os.type()), do: ".exe", else: ""
    p = Path.join([to_string(:code.priv_dir(:troupe)), "reaper", target(), "reaper" <> ext])
    if File.exists?(p), do: {:ok, p}, else: {:error, :reaper_missing}
  end

  @spec path!() :: String.t()
  def path! do
    case path() do
      {:ok, p} -> p
      {:error, :reaper_missing} -> raise "reaper binary missing for #{target()}; run mix compile"
    end
  end
end
