# The cluster tests kill the operator on purpose, so its crash reports are expected
# output rather than a signal. They are captured and printed only with a failure.
Logger.configure(level: :warning)

ExUnit.start(capture_log: true)
