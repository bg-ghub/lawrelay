require "test_helper"
require "tmpdir"
require "json"

class PrivacyPrivateJsonFileTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir("lawrelay-private-file-")
    File.chmod(0o700, @directory)
    @output = File.join(@directory, "review.json")
  end

  teardown do
    FileUtils.remove_entry_secure(@directory) if @directory && File.directory?(@directory)
  end

  test "Windows is refused rather than claiming private POSIX permissions" do
    original_platform = Gem.method(:win_platform?)
    Gem.define_singleton_method(:win_platform?) { true }
    assert_raises(Privacy::PrivateJsonFile::UnsafePath) { write(@output) }
    refute File.exist?(@output)
  ensure
    Gem.define_singleton_method(:win_platform?, original_platform) if original_platform
  end

  test "new output is private and cannot overwrite an existing file" do
    skip "POSIX file permissions are required" if Gem.win_platform?
    write(@output)
    assert_equal({ "review_required" => true }, JSON.parse(File.read(@output)))
    assert_equal 0o600, File.stat(@output).mode & 0o777
    original = File.read(@output)
    assert_raises(Privacy::PrivateJsonFile::UnsafePath) { write(@output) }
    assert_equal original, File.read(@output)
  end

  test "relative paths, missing folders and accessible folders are refused" do
    skip "POSIX file permissions are required" if Gem.win_platform?
    assert_raises(Privacy::PrivateJsonFile::UnsafePath) { write("review.json") }
    assert_raises(Privacy::PrivateJsonFile::UnsafePath) { write(File.join(@directory, "missing", "review.json")) }
    File.chmod(0o755, @directory)
    assert_raises(Privacy::PrivateJsonFile::UnsafePath) { write(@output) }
    refute File.exist?(@output)
  end

  test "symlink output and symlink ancestors are refused" do
    skip "POSIX file permissions are required" if Gem.win_platform?
    target = File.join(@directory, "existing.json")
    File.write(target, "keep")
    File.symlink(target, @output)
    assert_raises(Privacy::PrivateJsonFile::UnsafePath) { write(@output) }
    assert_equal "keep", File.read(target)
    File.symlink(@directory, File.join(@directory, "alias"))
    assert_raises(Privacy::PrivateJsonFile::UnsafePath) { write(File.join(@directory, "alias", "other.json")) }
    refute File.exist?(File.join(@directory, "other.json"))
  end

  test "application tree cannot receive privacy output" do
    skip "POSIX file permissions are required" if Gem.win_platform?
    assert_raises(Privacy::PrivateJsonFile::UnsafePath) { write(Rails.root.join("tmp", "privacy-review.json")) }
    traversing_path = "#{Rails.root.dirname}/#{Rails.root.basename}/../#{Rails.root.basename}/tmp/privacy-review.json"
    assert_raises(Privacy::PrivateJsonFile::UnsafePath) { write(traversing_path) }
  end

  private

  def write(path)
    Privacy::PrivateJsonFile.new(path).write!(review_required: true)
  end
end
