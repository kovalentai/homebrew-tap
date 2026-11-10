# frozen_string_literal: true

# Read by bashcov through SimpleCov. Run it with tests/coverage.sh, which passes
# the flags the numbers depend on and enforces the floor.

# Coverage is about the one script this tap ships; the test harness and its
# stand-in tools are not shipped code.
#
# A block, not a regexp: bashcov hands SimpleCov absolute paths, and its regexp
# filter does not match them.
SimpleCov.filters.clear
SimpleCov.add_filter { |file| file.filename.include?("/tests/") }
