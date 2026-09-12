# Logger output is noise here: the suite asserts on answers and on what the stub plane
# and the fake worker were sent, never on log lines.
Logger.configure(level: :critical)

ExUnit.start(capture_log: true)
