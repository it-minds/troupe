# Logger output is noise here: the suite asserts on answers and on what the stub plane
# and the fake worker were sent, never on log lines. The level is the VM's, which the
# next app's suite in the same `mix test` shares, so it is put back as this one ends.
level = Logger.level()
Logger.configure(level: :critical)

ExUnit.start(capture_log: true)
ExUnit.after_suite(fn _result -> Logger.configure(level: level) end)
