# frozen_string_literal: true

require_relative 'lib/pgdd/version'

Gem::Specification.new do |spec|
  spec.name    = 'pgdd'
  spec.version = Pgdd::VERSION
  spec.authors = ['Dewayne VanHoozer']
  spec.email   = ['dewayne@vanhoozer.me']

  spec.summary     = 'As-built database documentation and ERDs for a Rails application'
  spec.description = 'Boots a Rails application, reads its live database(s) and its ActiveRecord models, ' \
                     'and writes Markdown database documentation: an index, one page per table with columns, keys, ' \
                     'indexes, constraints, triggers, the migrations that changed it and the models backed by it, ' \
                     'plus Graphviz entity relationship diagrams that link back to the pages.'
  spec.homepage = 'https://github.com/madbomber/pgdd'
  spec.license  = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata = {
    'source_code_uri'       => spec.homepage,
    'changelog_uri'         => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  spec.files         = Dir['*.{md,txt}', '{lib,bin}/**/*']
  spec.bindir        = 'bin'
  spec.executables   = ['pgdd']
  spec.require_paths = ['lib']

  # No runtime dependencies: the gem runs inside the host application's own
  # Rails and ActiveRecord, and Graphviz `dot` is an external program.
end
