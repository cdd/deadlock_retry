require 'rubygems'
require_relative 'test_helper'

# Change the version if you want to test a different version of ActiveRecord
gem 'activerecord', ENV['ACTIVERECORD_VERSION'] || ' ~> 7.1.5.1'
require 'active_record'
require 'active_record/version'
puts "Testing ActiveRecord #{ActiveRecord::VERSION::STRING}"

require 'minitest'
require 'minitest/autorun'
require 'mocha'
require 'logger'
require_relative "../lib/deadlock_retry"

class MockModel
  @@open_transactions = 0

  class << self
    def transaction(requires_new: nil, isolation: nil, joinable: true)
      @@open_transactions += 1
      yield
    ensure
      @@open_transactions -= 1
    end

    def open_transactions
      @@open_transactions
    end

    def connection
      self
    end

    def logger
      @logger ||= Logger.new(nil)
    end

    def logger=(logger)
      @logger = logger
    end

    def show_innodb_status
      []
    end

    def select_rows(sql)
      [['version', '5.1.45']]
    end

    def select_value(sql)
      true
    end

    def select_all(sql)
      if sql == 'show innodb status'
        "FAKE INNODB STATUS HERE"
      elsif sql = 'show engine innodb status'
        "FAKE ENGINE INNODB STATUS HERE"
      else
        raise "Unknown SQL: #{sql}"
      end
    end

    def adapter_name
      "MySQL"
    end
  end

  singleton_class.prepend DeadlockRetry
end

module NoPause
  def exponential_pause(_)
    # No pause!
  end
end
MockModel.singleton_class.prepend(NoPause)

class DeadlockRetryTest < Minitest::Test
  DEADLOCK_ERROR = "MySQL::Error: Deadlock found when trying to get lock"
  TIMEOUT_ERROR = "MySQL::Error: Lock wait timeout exceeded"

  def setup
    DeadlockRetry.class_variable_set(:@@deadlock_logger_severity, nil)
  end

  def test_no_errors
    assert_equal :success, MockModel.transaction { :success }
  end

  def test_no_errors_with_hash_params
    assert_equal :success, MockModel.transaction(:requires_new => false) { :success }
  end

  def test_no_errors_with_hash_kw_params
    assert_equal :success, MockModel.transaction(requires_new: false) { :success }
  end

  def test_no_errors_with_deadlock
    errors = [ DEADLOCK_ERROR ] * 3
    assert_equal :success, MockModel.transaction { raise ActiveRecord::Deadlocked, errors.shift unless errors.empty?; :success }
    assert errors.empty?
  end

  def test_no_errors_with_lock_timeout
    errors = [ TIMEOUT_ERROR ] * 3
    assert_equal :success, MockModel.transaction { raise ActiveRecord::LockWaitTimeout, errors.shift unless errors.empty?; :success }
    assert errors.empty?
  end

  def test_error_if_limit_exceeded_with_deadlock
    assert_raises(ActiveRecord::StatementInvalid) do
      MockModel.transaction { raise ActiveRecord::Deadlocked, DEADLOCK_ERROR }
    end
  end

  def test_error_if_limit_exceeded_with_lock_timeout
    assert_raises(ActiveRecord::StatementInvalid) do
      MockModel.transaction { raise ActiveRecord::LockWaitTimeout, TIMEOUT_ERROR }
    end
  end

  def test_logs_at_level_info_by_default_with_deadlock
    log_io = StringIO.new
    log = Logger.new(log_io)
    MockModel.logger = log
    test_no_errors_with_deadlock
    log_io.rewind
    logs = log_io.read
    [1, 2, 3].each do |i|
      assert_match(/INFO -- : Deadlock detected on retry #{i}, restarting transaction \[ActiveRecord::Deadlocked\]/, logs)
    end
  end

  def test_logs_at_level_info_by_default_with_lock_timeout
    log_io = StringIO.new
    log = Logger.new(log_io)
    MockModel.logger = log
    test_no_errors_with_lock_timeout
    log_io.rewind
    logs = log_io.read
    [1, 2, 3].each do |i|
      assert_match(/INFO -- : Deadlock detected on retry #{i}, restarting transaction \[ActiveRecord::LockWaitTimeout\]/, logs)
    end
  end

  def test_error_if_unrecognized_error
    assert_raises(ActiveRecord::StatementInvalid) do
      MockModel.transaction { raise ActiveRecord::StatementInvalid, "Something else" }
    end
  end

  def test_included_by_default
    assert ActiveRecord::Base.singleton_class.ancestors.member?(DeadlockRetry)
  end

  def test_innodb_status_availability
    DeadlockRetry.innodb_status_cmd = nil
    MockModel.transaction {}
    assert_equal "show innodb status", DeadlockRetry.innodb_status_cmd
  end

  def test_error_in_nested_transaction_should_retry_outermost_transaction_with_lock_timeout
    tries = 0
    errors = 0

    MockModel.transaction do
      tries += 1
      MockModel.transaction do
        MockModel.transaction do
          errors += 1
          raise ActiveRecord::LockWaitTimeout, "MySQL::Error: Lock wait timeout exceeded" unless errors > 3
        end
      end
    end

    assert_equal 4, tries
  end

  def test_error_in_nested_transaction_should_retry_outermost_transaction_with_deadlock
    tries = 0
    errors = 0

    MockModel.transaction do
      tries += 1
      MockModel.transaction do
        MockModel.transaction do
          errors += 1
          raise ActiveRecord::Deadlocked, "MySQL::Error: Deadlock found when trying to get lock" unless errors > 3
        end
      end
    end

    assert_equal 4, tries
  end
end
