require "test_helper"

class RoutesTest < ActionDispatch::IntegrationTest
  test "marketplace routes resolve to their intended controllers" do
    assert_routing "/", controller: "home", action: "index"
    assert_routing "/assignments", controller: "assignments", action: "index"
    assert_routing "/assignments/new", controller: "assignments", action: "new"
    assert_routing "/assignments/12", controller: "assignments", action: "show", id: "12"
    assert_routing({ method: "post", path: "/assignments/12/proposals" }, controller: "proposals", action: "create", assignment_id: "12")
    assert_routing "/dashboard", controller: "dashboard", action: "index"
  end

  test "locale-prefixed marketplace routes retain English slugs" do
    assert_routing "/nl/assignments", controller: "assignments", action: "index", locale: "nl"
    assert_routing "/fr/assignments/new", controller: "assignments", action: "new", locale: "fr"
    assert_routing "/de/assignments/12", controller: "assignments", action: "show", id: "12", locale: "de"
    assert_routing({ method: "post", path: "/en/assignments/12/proposals" }, controller: "proposals", action: "create", assignment_id: "12", locale: "en")
    assert_routing "/de/dashboard", controller: "dashboard", action: "index", locale: "de"
  end
end
