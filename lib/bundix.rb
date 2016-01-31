require 'bundler'
require 'json'
require 'open-uri'
require 'open3'
require 'pp'

require_relative 'bundix/source'

class Bundix
  VERSION = '2.0.1'

  NIX_INSTANTIATE = 'nix-instantiate'
  NIX_PREFETCH_URL = 'nix-prefetch-url'
  NIX_PREFETCH_GIT = 'nix-prefetch-git'
  NIX_HASH = 'nix-hash'

  SHA256_32 = %r(^[a-z0-9]{52}$)
  SHA256_16 = %r(^[a-f0-9]{64}$)

  attr_reader :options

  def initialize(options)
    @options = {
      gemset: './gemset.nix',
      lockfile: './Gemfile.lock',
      quiet: false,
      tempfile: nil,
      deps: false
    }.merge(options)
  end

  def convert
    cache = parse_gemset
    lock = parse_lockfile

    # reverse so git comes last
    lock.specs.reverse_each.with_object({}) do |spec, gems|
      name, cached = cache.find{|k, v|
        k == spec.name &&
          v['version'] == spec.version.to_s &&
          v.dig('source', 'sha256').to_s.size == 52
      }

      if cached
        gems[name] = cached
        next
      end

      gems[spec.name] = {
        version: spec.version.to_s,
        source: Source.new(spec).convert
      }

      if options[:deps] && spec.dependencies.any?
        gems[spec.name][:dependencies] = spec.dependencies.map(&:name) - ['bundler']
      end
    end
  end

  def parse_gemset
    path = File.expand_path(options[:gemset])
    return {} unless File.file?(path)
    json = Bundix.sh(
      NIX_INSTANTIATE, '--eval', '-E', "builtins.toJSON(import #{path})")
    JSON.parse(json.strip.gsub(/\\"/, '"')[1..-2])
  end

  def parse_lockfile
    Bundler::LockfileParser.new(File.read(options[:lockfile]))
  end

  def self.object2nix(obj, level = 2, out = '')
    case obj
    when Hash
      out << "{\n"
      obj.each do |k, v|
        out << ' ' * level
        if k.to_s =~ /^[a-zA-Z_-]+[a-zA-Z0-9_-]*$/
          out << k.to_s
        else
          object2nix(k, level + 2, out)
        end
        out << ' = '
        object2nix(v, level + 2, out)
        out << (v.is_a?(Hash) ? "\n" : ";\n")
      end
      out << (' ' * (level - 2)) << (level == 2 ? '}' : '};')
    when Array
      out << '[' << obj.map{|o| o.to_str.dump }.join(' ') << ']'
    when String
      out << obj.dump
    when Symbol
      out << obj.to_s.dump
    when true, false
      out << obj.to_s
    else
      fail obj.inspect
    end
  end

  def self.sh(*args)
    out, status = Open3.capture2e(*args)
    unless status.success?
      puts "$ #{args.join(' ')}" if $VERBOSE
      puts out if $VERBOSE
      fail "command execution failed: #{status}"
    end
    out
  end
end
