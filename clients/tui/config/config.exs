import Config

config :logger, level: :info

if config_env() == :test do
  config :logger, level: :warning
  config :troupe, ui: :none
end

import_config "#{config_env()}.exs"

config :troupe_gateway, autostart: false
