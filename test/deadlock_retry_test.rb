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
  def sleep_pause(_)
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

  def print_logs(logs)
    puts "\n"
    puts "*" * 100
    puts logs
    puts "@" * 100
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
    assert_raises(ActiveRecord::Deadlocked) do
      MockModel.transaction do
        # this code will run a few times, but the raise will eventually break through
        raise ActiveRecord::Deadlocked, DEADLOCK_ERROR
      end
    end
  end

  def test_error_if_limit_exceeded_with_lock_timeout
    assert_raises(ActiveRecord::LockWaitTimeout) do
      MockModel.transaction do
        # this code will run a few times, but the raise will eventually break through
        raise ActiveRecord::LockWaitTimeout, TIMEOUT_ERROR
      end
    end
  end

  def test_logs_at_level_info_by_default_with_deadlock
    log_io = StringIO.new
    log = Logger.new(log_io)
    MockModel.logger = log
    test_no_errors_with_deadlock
    log_io.rewind
    logs = log_io.read

    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 1, retrying transaction in 0 seconds. [ActiveRecord::Deadlocked]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 2, retrying transaction in 1 seconds. [ActiveRecord::Deadlocked]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 3, retrying transaction in 2 seconds. [ActiveRecord::Deadlocked]")
  end

  def test_logs_at_level_info_by_default_with_lock_timeout
    log_io = StringIO.new
    log = Logger.new(log_io)
    MockModel.logger = log
    test_no_errors_with_lock_timeout
    log_io.rewind
    logs = log_io.read
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 1, retrying transaction in 0 seconds. [ActiveRecord::LockWaitTimeout]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 2, retrying transaction in 1 seconds. [ActiveRecord::LockWaitTimeout]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 3, retrying transaction in 2 seconds. [ActiveRecord::LockWaitTimeout]")
  end

  def test_logs_if_limit_exceeded_with_deadlock
    log_io = StringIO.new
    log = Logger.new(log_io)
    MockModel.logger = log

    assert_raises(ActiveRecord::Deadlocked) do
      MockModel.transaction { raise ActiveRecord::Deadlocked, DEADLOCK_ERROR }
    end

    log_io.rewind
    logs = log_io.read

    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 1, retrying transaction in 0 seconds. [ActiveRecord::Deadlocked]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 2, retrying transaction in 1 seconds. [ActiveRecord::Deadlocked]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 3, retrying transaction in 2 seconds. [ActiveRecord::Deadlocked]")
    refute_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 4")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_MAXIMUM_RETRIES_EXCEEDED Deadlock detected and maximum retries exceeded (maximum: 3), not retrying. [ActiveRecord::Deadlocked]")
  end

  def test_logs_if_limit_exceeded_with_lock_timeout
    log_io = StringIO.new
    log = Logger.new(log_io)
    MockModel.logger = log

    assert_raises(ActiveRecord::LockWaitTimeout) do
      MockModel.transaction { raise ActiveRecord::LockWaitTimeout, TIMEOUT_ERROR }
    end

    test_no_errors_with_lock_timeout
    log_io.rewind
    logs = log_io.read

    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 1, retrying transaction in 0 seconds. [ActiveRecord::LockWaitTimeout]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 2, retrying transaction in 1 seconds. [ActiveRecord::LockWaitTimeout]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 3, retrying transaction in 2 seconds. [ActiveRecord::LockWaitTimeout]")
    refute_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 4")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_MAXIMUM_RETRIES_EXCEEDED Deadlock detected and maximum retries exceeded (maximum: 3), not retrying. [ActiveRecord::LockWaitTimeout]")
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

  def test_error_in_nested_transaction_should_retry_outermost_transaction_with_deadlock
    tries = 0
    errors = 0

    MockModel.transaction do
      tries += 1
      MockModel.transaction do
        MockModel.transaction do
          errors += 1
          raise ActiveRecord::Deadlocked, DEADLOCK_ERROR unless errors > 3
        end
      end
    end

    assert_equal 4, tries
  end

  def test_error_in_nested_transaction_should_retry_outermost_transaction_with_lock_timeout
    tries = 0
    errors = 0

    MockModel.transaction do
      tries += 1
      MockModel.transaction do
        MockModel.transaction do
          errors += 1
          raise ActiveRecord::LockWaitTimeout, TIMEOUT_ERROR unless errors > 3
        end
      end
    end

    assert_equal 4, tries
  end

  def test_logs_in_nested_transaction_with_deadlock
    log_io = StringIO.new
    log = Logger.new(log_io)
    MockModel.logger = log

    assert_raises(ActiveRecord::Deadlocked) do
      MockModel.transaction do
        MockModel.transaction do
          MockModel.transaction do
            raise ActiveRecord::Deadlocked, DEADLOCK_ERROR
          end
        end
      end
    end

    log_io.rewind
    logs = log_io.read

    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 1, retrying transaction in 0 seconds. [ActiveRecord::Deadlocked]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 2, retrying transaction in 1 seconds. [ActiveRecord::Deadlocked]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 3, retrying transaction in 2 seconds. [ActiveRecord::Deadlocked]")
    refute_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 4")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_MAXIMUM_RETRIES_EXCEEDED Deadlock detected and maximum retries exceeded (maximum: 3), not retrying. [ActiveRecord::Deadlocked]")
    assert_equal 8, logs.scan("CDD_DEADLOCK_RETRY_NESTED_TRANSACTION Deadlock detected in a nested transaction, not retrying. [ActiveRecord::Deadlocked]").size
  end

  def test_logs_in_nested_transaction_with_deadlock
    log_io = StringIO.new
    log = Logger.new(log_io)
    MockModel.logger = log

    assert_raises(ActiveRecord::LockWaitTimeout) do
      MockModel.transaction do
        MockModel.transaction do
          MockModel.transaction do
            raise ActiveRecord::LockWaitTimeout, TIMEOUT_ERROR
          end
        end
      end
    end

    log_io.rewind
    logs = log_io.read

    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 1, retrying transaction in 0 seconds. [ActiveRecord::LockWaitTimeout]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 2, retrying transaction in 1 seconds. [ActiveRecord::LockWaitTimeout]")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 3, retrying transaction in 2 seconds. [ActiveRecord::LockWaitTimeout]")
    refute_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry 4")
    assert_includes(logs, "INFO -- : CDD_DEADLOCK_RETRY_MAXIMUM_RETRIES_EXCEEDED Deadlock detected and maximum retries exceeded (maximum: 3), not retrying. [ActiveRecord::LockWaitTimeout]")
    assert_equal 8, logs.scan("CDD_DEADLOCK_RETRY_NESTED_TRANSACTION Deadlock detected in a nested transaction, not retrying. [ActiveRecord::LockWaitTimeout]").size
  end
end
