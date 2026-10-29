require "json"
require "pathname"

module Privacy
  class PrivateJsonFile
    class UnsafePath < StandardError; end

    def initialize(path)
      @path = Pathname.new(path.to_s)
      @created = false
    end

    def write!(data)
      raise UnsafePath, "Use a protected POSIX server terminal; Windows ACLs are not handled by this helper." if Gem.win_platform?
      raise UnsafePath, "Use an absolute output path." unless @path.absolute?

      directory = @path.dirname
      canonical_directory = directory.realpath
      app_root = Rails.root.realpath.to_s
      if canonical_directory.to_s == app_root || canonical_directory.to_s.start_with?("#{app_root}/")
        raise UnsafePath, "Keep privacy review files outside the application tree."
      end
      safe_directory = directory.directory? && canonical_directory == directory.cleanpath &&
        directory.stat.uid == Process.euid && (directory.stat.mode & 0o077).zero?
      raise UnsafePath, "Create an owned private output directory (mode 0700) first." unless safe_directory

      File.open(@path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        @created = true
        raise UnsafePath, "Output file permissions are not private." unless (file.stat.mode & 0o077).zero?

        file.write(JSON.pretty_generate(data))
        file.write("\n")
        file.flush
        file.fsync
      end
    rescue Errno::EEXIST, Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
      raise UnsafePath, "Output must be a new file in an existing private directory."
    end

    def remove_created!
      @path.unlink if @created && @path.file?
      @created = false
    end
  end
end
