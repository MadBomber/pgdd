# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in pgdd.gemspec
gemspec

# Everything below is for working on pgdd itself; users get only what the
# gemspec declares (nothing: it runs inside the host application's Rails).
group :development, :test do
  gem "irb"
  gem "minitest", "~> 5.16"
  gem "rake", "~> 13.0"

  # Quality gate (asgard quality)
  gem "bundler-audit"  # Patch-level verification for Bundler
  gem "fasterer"       # Performance suggestions
  gem "flay"           # Structural duplication
  gem "flog"           # Complexity
  gem "reek"           # Code smells
  gem "rubocop", ">= 1.80" # Style
end
