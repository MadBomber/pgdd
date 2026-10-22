# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class CLITest < Minitest::Test
  def cli
    @out = StringIO.new
    @err = StringIO.new
    Pgdd::CLI.new(out: @out, err: @err)
  end

  def test_defaults
    options = cli.parse_options([])

    assert_equal File.expand_path('.'), options[:root]
    assert_nil options[:output]
    assert_equal [], options[:databases]
    assert_equal 'svg', options[:erd_format]
    assert options[:erd]
    refute options[:count_rows]
    refute options[:include_internal]
    refute options[:all_databases]
  end

  def test_every_flag
    options = cli.parse_options(%w[-e production -o docs/db -d primary -d queue -a -c -i -f dot --no-erd /srv/app])

    assert_equal 'production', options[:environment]
    assert_equal File.expand_path('docs/db'), options[:output]
    assert_equal %w[primary queue], options[:databases]
    assert options[:all_databases]
    assert options[:count_rows]
    assert options[:include_internal]
    assert_equal 'dot', options[:erd_format]
    refute options[:erd]
    assert_equal '/srv/app', options[:root]
  end

  def test_defaults_are_not_shared_between_parses
    c = cli
    c.parse_options(%w[-d queue])

    assert_equal [], c.parse_options([])[:databases]
  end

  def test_command_line_is_the_invocation_as_typed
    assert_equal 'pgdd', cli.command_line([])
    assert_equal 'pgdd -d primary -o docs/db', cli.command_line(%w[-d primary -o docs/db])
    assert_equal 'pgdd -o "my docs"', cli.command_line(['-o', 'my docs'])
  end

  def test_help_and_version_exit_zero
    c = cli

    assert_equal 0, c.run(%w[--help])
    assert_includes @out.string, 'Usage: pgdd [options] [RAILS_ROOT]'
    assert_includes @out.string, '--erd-format FORMAT'

    assert_equal 0, cli.run(%w[--version])
    assert_equal "pgdd #{Pgdd::VERSION}\n", @out.string
  end

  def test_unknown_option_exits_one
    assert_equal 1, cli.run(%w[--bogus])
    assert_includes @err.string, 'ERROR: invalid option: --bogus'
  end

  def test_bad_erd_format_exits_one
    assert_equal 1, cli.run(%w[-f gif])
    assert_includes @err.string, 'ERROR: invalid argument: -f gif'
  end

  def test_directory_without_a_rails_app_exits_one
    Dir.mktmpdir do |dir|
      assert_equal 1, cli.run([dir])
      assert_equal "ERROR: not a Rails application: #{dir}\n", @err.string
    end
  end
end
