# frozen_string_literal: true

require 'date'
require 'erb'
require 'fileutils'
require 'optparse'
require 'pathname'

# Pgdd boots a Rails application and writes as-built database documentation from
# its live database(s) and its ActiveRecord models: a Markdown index, one page
# per table, and Graphviz entity relationship diagrams.
#
# The pipeline is Collector (database + models -> App) -> Report (App ->
# Markdown pages) and ErdWriter (Database -> DOT/SVG). CLI wires them to the
# command line; the Railtie adds the pgdd:generate rake task.
module Pgdd
  class Error < StandardError; end
end

require_relative 'pgdd/version'
require_relative 'pgdd/types'
require_relative 'pgdd/migration_scanner'
require_relative 'pgdd/database_inspector'
require_relative 'pgdd/model_inspector'
require_relative 'pgdd/erd_writer'
require_relative 'pgdd/report'
require_relative 'pgdd/collector'
require_relative 'pgdd/cli'
require_relative 'pgdd/railtie' if defined?(Rails::Railtie)
