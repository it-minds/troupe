defmodule Troupe.Plane.Settings.Setting do
  @moduledoc "One thing about this plane that has a value."

  @enforce_keys [:key, :group, :type, :summary, :consequence]
  defstruct [
    :key,
    :group,
    :type,
    :label,
    :unit,
    :choices,
    :summary,
    :consequence,
    :values,
    :app_key,
    :fallback,
    effect: :immediate,
    editable: true,
    secret: false
  ]

  @typedoc """
  How a person reads and types the value, which is not always how it is kept: a `:dollars`
  setting holds millionths of a dollar and a `:minutes` one holds seconds, so a surface
  converts both ways and the value on the wire stays the plane's.
  """
  @type unit ::
          :days
          # Days, where 0 is off: a retention period nobody set.
          | :days_or_off
          | :hours
          | :minutes
          | :seconds
          | :dollars
          | :bytes
          | :count
          | :switch
          | :text
          | :choice
          | :url

  @doc "Every unit a setting may be read in."
  @spec units() :: [unit()]
  def units,
    do: [:days, :days_or_off, :hours, :minutes, :seconds, :dollars, :bytes, :count, :switch, :text, :choice, :url]

  @type t :: %__MODULE__{
          key: String.t(),
          # Which panel of the Settings page it appears in. Carried by the setting rather
          # than by the page so that adding one is a change to this list and nothing else.
          group: atom(),
          # `:enum` is a string with a closed set of values; `:list` is words separated by
          # commas or spaces, stored as typed and read as a list; `:enforced` is a JSON
          # object of the keys an organisation holds people's machines to, checked by
          # `Troupe.Protocol.Organisation`; the rest are what they say.
          type: :string | :integer | :boolean | :enum | :list | :enforced,
          # The reader's name for it, a short noun phrase a row is headed with; the key
          # stays what a caller sends.
          label: String.t() | nil,
          unit: unit() | nil,
          # A `:choice`'s values, each with the words a person picks it by, in the order
          # they are offered. The same values as `values`, which the settings test holds.
          choices: [{atom(), String.t()}] | nil,
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
