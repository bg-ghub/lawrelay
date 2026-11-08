require "image_processing/vips"
require "json"

raise "Expected libvips for Rails variants" unless ActiveStorage.variant_processor == :vips

source = Rails.root.join("public/pwa-icon-192.png")
processed = nil

begin
  processed = ImageProcessing::Vips.source(source.to_s).resize_to_limit(24, 24).convert("png").call
  direct_image = Vips::Image.new_from_file(processed.path)
  raise "ImageProcessing resize failed" unless [ direct_image.width, direct_image.height ] == [ 24, 24 ]
  raise "ImageProcessing output is not PNG" unless File.binread(processed.path, 8) == "\x89PNG\r\n\x1A\n".b

  rails_size = File.open(source, "rb") do |input|
    ActiveStorage::Variation.wrap(resize_to_fill: [ 18, 12 ], format: :png).transform(input) do |output|
      raise "Rails output is not PNG" unless output.read(8) == "\x89PNG\r\n\x1A\n".b
      image = Vips::Image.new_from_file(output.path)
      [ image.width, image.height ]
    end
  end
  raise "Rails variant transformation failed" unless rails_size == [ 18, 12 ]

  puts JSON.generate(image_processing: Gem.loaded_specs.fetch("image_processing").version.to_s,
    backend: ActiveStorage.variant_processor, libvips: Vips.version_string,
    direct_png_size: [ direct_image.width, direct_image.height ], rails_png_size: rails_size)
ensure
  processed&.close!
end
