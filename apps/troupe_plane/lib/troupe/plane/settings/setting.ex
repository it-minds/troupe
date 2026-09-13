defmodule Troupe.Plane.Settings.Setting do
  @moduledoc "One thing about this plane that has a value."

  @enforce_keys [:key, :group, :type, :summary, :consequence]
  defstruct [
    :key,
    :group,
    :type,
    :summary,
    :consequence,
    :values,
    :app_key,
    :fallback,
    effect: :immediate,
    editable: true,
    secret: false
  ]

  @type t :: %__MODULE__{
          key: String.t(),
          # Which panel of the Settings page it appears in. Carried by the setting rather
          # than by the page so that adding one is a change to this list and nothing else.
          group: atom(),
          # `:enum` is a string with a closed set of values; the rest are what they say.
          type: :string | :integer | :boolean | :enum,
          summary: String.t(),
          # What changes when this changes. Shown next to the field, because a setting
          # whose effect a reader has to guess is one they will not touch.
          consequence: String.t(),
          values: [String.t()] | nil,
          # Where the deployed value lives in the application environment. An atom, or a
          # path for a value nested in a keyword list.
          app_key: atom() | [atom()] | nil,
          fallback: term(),
          effect: :immediate | :next_team | :next_session | :restart,
          editable: boolean(),
          secret: boolean()
        }
end
