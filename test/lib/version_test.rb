require "test_helper"

class VersionTest < ActiveSupport::TestCase
  test "application version follows semantic versioning" do
    semver = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/

    assert_match semver, LawRelay::VERSION
    assert_equal Rails.root.join("VERSION").read.strip, LawRelay::VERSION
  end
end
