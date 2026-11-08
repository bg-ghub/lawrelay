require "test_helper"

class ImageProcessingCompatibilityTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  SOURCE_IMAGE = Rails.root.join("public/pwa-icon-192.png")

  setup do
    require "image_processing/vips"
  rescue LoadError => error
    # Linux CI and the production-image smoke must exercise the native backend.
    # Keep unrelated local tests usable on Windows without a libvips DLL.
    if Gem.win_platform? && error.cause&.message&.include?("libvips-42.dll")
      skip "Native Windows libvips is unavailable; the Linux CI and production-image checks cover this pipeline"
    end
    raise
  end

  test "the explicit Vips pipeline resizes a transparent PNG" do
    assert_equal :vips, Rails.application.config.active_storage.variant_processor

    output = ImageProcessing::Vips.source(SOURCE_IMAGE.to_s)
      .resize_to_limit(48, 48)
      .convert("png")
      .call

    image = Vips::Image.new_from_file(output.path)
    assert_equal 48, image.width
    assert_equal 48, image.height
    assert image.has_alpha?
  ensure
    output&.close!
  end

  test "Active Storage variations use Vips to transform the transparent PNG" do
    variation = ActiveStorage::Variation.wrap(resize_to_limit: [ 32, 32 ], format: :png)

    File.open(SOURCE_IMAGE, "rb") do |input|
      variation.transform(input) do |output|
        image = Vips::Image.new_from_file(output.path)
        assert_equal 32, image.width
        assert_equal 32, image.height
        assert image.has_alpha?
      end
    end
  end
end
