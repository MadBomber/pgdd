# frozen_string_literal: true

module Pgdd
  # Adds the pgdd:generate rake task to applications that bundle the gem
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path('../tasks/pgdd.rake', __dir__)
    end
  end
end
