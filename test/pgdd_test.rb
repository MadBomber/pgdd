# frozen_string_literal: true

require 'test_helper'

class PgddTest < Minitest::Test
  def test_has_a_version_number
    assert_match(/\A\d+\.\d+\.\d+/, Pgdd::VERSION)
  end

  def test_errors_share_a_base_class
    assert_operator Pgdd::ErdWriter::Error, :<, Pgdd::Error
  end
end
