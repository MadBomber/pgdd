# frozen_string_literal: true

module Pgdd
  # The pgdd command: parses options, boots the application unless it is
  # already loaded (bin/rails runner, a rake task), collects, and writes
  class CLI
    DEFAULTS = { environment: nil, output: nil, count_rows: false, include_internal: false, databases: [],
                 all_databases: false, erd: true, erd_format: 'svg' }.freeze

    # Runs with argv and returns the process exit status
    def self.run(argv, out: $stdout, err: $stderr)
      new(out: out, err: err).run(argv)
    end

    def initialize(out: $stdout, err: $stderr)
      @out = out
      @err = err
    end

    def run(argv)
      options = parse_options(argv)
      return show(options[:help]) if options[:help]

      root = rails_root(options)
      return fail_with("not a Rails application: #{root}") unless File.exist?(File.join(root, 'config', 'environment.rb'))

      boot(root, options[:environment])
      ActiveRecord::Base.logger = nil
      app = ActiveRecord::Base.while_preventing_writes do
        Collector.new(root: root, **options.slice(:count_rows, :include_internal, :databases, :all_databases)).call
      end
      write(app, options, command_line(argv))
    rescue OptionParser::ParseError, ErdWriter::Error => e
      fail_with(e.message)
    rescue Errno::ENOENT => e
      raise unless e.message.end_with?('- dot')

      fail_with('Graphviz dot not found; install graphviz or use --erd-format dot')
    end

    def show(text)
      @out.puts text
      0
    end

    def fail_with(message)
      @err.puts "ERROR: #{message}"
      1
    end

    # Rails.root when running inside the application, else the argument
    def rails_root(options)
      defined?(::Rails.root) && ::Rails.root ? ::Rails.root.to_s : options[:root]
    end

    # The pages and diagrams into the output directory, or the index to STDOUT
    def write(app, options, command)
      dir        = options[:output]
      erd_format = options[:erd] && dir ? options[:erd_format] : nil
      report     = Report.new(app, erd_format: erd_format, output_dir: dir, command: command)

      if dir
        FileUtils.mkdir_p(dir)
        report.pages.each { |name, markdown| File.write(File.join(dir, name), markdown) }
        write_erds(app, report, dir, erd_format) if erd_format
      else
        @out.print report.index_markdown
      end
      0
    end

    # The invocation as typed, for the generated README
    def command_line(argv)
      (['pgdd'] + argv.map { |a| a.match?(/[\s"']/) ? a.inspect : a }).join(' ')
    end

    # The option hash for argv; :root is the Rails root argument, expanded
    def parse_options(argv)
      options = DEFAULTS.transform_values(&:dup)

      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: pgdd [options] [RAILS_ROOT]'
        opts.on('-e', '--environment ENV', 'Rails environment (default: RAILS_ENV or development)') { |v| options[:environment] = v }
        opts.on('-o', '--output DIR', "Write #{Report::INDEX}, a page per table and the diagrams to DIR",
                "(without it only #{Report::INDEX} is written, to STDOUT)") { |v| options[:output] = File.expand_path(v) }
        opts.on('-d', '--database NAME', 'Report this database config (repeatable; default: the primary only)') { |v| options[:databases] << v }
        opts.on('-a', '--all-databases', 'Report every database config (cache, queue, cable, ...)') { options[:all_databases] = true }
        opts.on('-c', '--count', 'Exact row counts with SELECT COUNT(*) (can be slow)') { options[:count_rows] = true }
        opts.on('-i', '--internal', 'Include schema_migrations and ar_internal_metadata') { options[:include_internal] = true }
        opts.on('-f', '--erd-format FORMAT', ErdWriter::FORMATS, "ERD format: #{ErdWriter::FORMATS.join(', ')} (default: svg; needs Graphviz dot unless dot)") { |v| options[:erd_format] = v }
        opts.on('--no-erd', 'Skip the ERD diagrams') { options[:erd] = false }
        opts.on('-v', '--version', 'Show the version') { options[:help] = "pgdd #{VERSION}" }
        opts.on('-h', '--help', 'Show this help') { options[:help] = opts.help }
      end

      options[:root] = File.expand_path(parser.parse(argv).first || '.')
      options
    end

    # Loads the application unless we are already inside it
    def boot(root, environment)
      return if defined?(::Rails.application) && ::Rails.application

      ENV['RAILS_ENV'] = environment if environment
      ENV['RAILS_ENV'] ||= 'development'
      Dir.chdir(root)
      require File.join(root, 'config', 'environment')
    end

    # Diagrams share the report's file stems so the pages and the links inside the SVGs line up
    def write_erds(app, report, dir, format)
      app.databases.reject(&:error).flat_map do |db|
        models = app.models.select { |m| m.database == db.name }
        ErdWriter.new(db, models: models, name_for: ->(table_name) { report.basename(db.name, table_name) }).write(dir, format: format)
      end
    end
  end
end
