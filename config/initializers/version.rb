version = Rails.root.join("VERSION").read.strip

unless version.match?(/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z/)
  raise "VERSION must contain a valid Semantic Version"
end

LawRelay.const_set(:VERSION, version.freeze)
