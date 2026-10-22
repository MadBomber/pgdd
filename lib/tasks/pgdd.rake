# frozen_string_literal: true

namespace :pgdd do
  desc 'Write the database documentation and ERDs to OUTPUT (default docs/database); extra pgdd flags in PGDD_OPTIONS'
  task :generate, [:output] => :environment do |_task, args|
    output = args[:output] || ENV.fetch('PGDD_OUTPUT', 'docs/database')
    argv   = ['--output', output] + ENV.fetch('PGDD_OPTIONS', '').split
    status = Pgdd::CLI.run(argv)
    raise "pgdd exited with status #{status}" unless status.zero?
  end
end
