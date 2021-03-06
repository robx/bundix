class Bundix
  class Fetcher
    def sh(*args, &block)
      Bundix.sh(*args, &block)
    end

    def download(file, url)
      warn "Downloading #{file} from #{url}"
      uri = URI(url)
      open_options = {}
      if uri.user
        open_options[:http_basic_authentication] = [uri.user, uri.password]
        uri.user = nil
        uri.password = nil
      end

      open(uri.to_s, 'r', 0600, open_options) do |net|
        File.open(file, 'wb+') { |local|
          File.copy_stream(net, local)
        }
      end
    end

    def nix_prefetch_url(url)
      dir = File.expand_path('~/.cache/bundix')
      FileUtils.mkdir_p dir
      file = File.join(dir, url.gsub(/[^\w-]+/, '_'))

      download(file, url) unless File.size?(file)
      return unless File.size?(file)

      sh('nix-prefetch-url', '--type', 'sha256', "file://#{file}")
        .force_encoding('UTF-8').strip
    rescue => ex
      puts ex
      nil
    end

    def nix_prefetch_git(uri, revision)
      home = ENV['HOME']
      ENV['HOME'] = '/homeless-shelter'
      sh(NIX_PREFETCH_GIT, '--url', uri, '--rev', revision, '--hash', 'sha256', '--leave-dotGit')
    ensure
      ENV['HOME'] = home
    end

    def format_hash(hash)
      sh(NIX_HASH, '--type', 'sha256', '--to-base32', hash)[SHA256_32]
    end

    def fetch_local_hash(spec)
      spec.source.caches.each do |cache|
        path = File.join(cache, "#{spec.full_name}.gem")
        next unless File.file?(path)
        hash = nix_prefetch_url(path)[SHA256_32]
        return format_hash(hash) if hash
      end

      nil
    end

    def fetch_remotes_hash(spec, remotes)
      remotes.each do |remote|
        hash = fetch_remote_hash(spec, remote)
        return remote, format_hash(hash) if hash
      end

      nil
    end

    def fetch_remote_hash(spec, remote)
      uri = "#{remote}/gems/#{spec.full_name}.gem"
      result = nix_prefetch_url(uri)
      return unless result
      result[SHA256_32]
    rescue => e
      puts "ignoring error during fetching: #{e}"
      puts e.backtrace
      nil
    end
  end

  class Source < Struct.new(:spec, :fetcher)
    def convert
      case spec.source
      when Bundler::Source::Rubygems
        convert_rubygems
      when Bundler::Source::Git
        convert_git
      when Bundler::Source::Path
        convert_path
      else
        pp spec
        fail 'unkown bundler source'
      end
    end

    def convert_path
      {
        type: "path",
        path: spec.source.path
      }
    end

    def convert_rubygems
      remotes = spec.source.remotes.map{|remote| remote.to_s.sub(/\/+$/, '') }
      hash = fetcher.fetch_local_hash(spec)
      remote, hash = fetcher.fetch_remotes_hash(spec, remotes) unless hash
      fail "couldn't fetch hash for #{spec.full_name}" unless hash
      puts "#{hash} => #{spec.full_name}.gem" if $VERBOSE

      { type: 'gem',
        remotes: (remote ? [remote] : remotes),
        sha256: hash }
    end

    def convert_git
      revision = spec.source.options.fetch('revision')
      uri = spec.source.options.fetch('uri')
      output = fetcher.nix_prefetch_git(uri, revision)
      # FIXME: this is a hack, we should separate $stdout/$stderr in the sh call
      hash = JSON.parse(output[/({[^}]+})\s*\z/m])['sha256']
      fail "couldn't fetch hash for #{spec.full_name}" unless hash
      puts "#{hash} => #{uri}" if $VERBOSE

      { type: 'git',
        url: uri.to_s,
        rev: revision,
        sha256: hash,
        fetchSubmodules: false }
    end
  end
end
